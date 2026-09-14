#[compute]
#version 450

// Line-based liquid pressure solver, run after each Margolus tick.
//
// Pairwise averaging inside 2x2x2 blocks only moves pressure at diffusion
// speed, far too slow for pipes and U-bends. Here one thread owns a whole line
// of the grid (no write hazards) and, within each contiguous run of one liquid:
//   mode 0 (columns, along y): sets the exact hydrostatic profile, bottom cells
//     compressed by COMP per cell of liquid above, surplus at the top;
//   mode 1 / 2 (rows, along x / z): relaxes amounts toward the run's mean by
//     `rate`, which carries pressure sideways at run length per tick.
// Runs never cross air, walls, other liquids or gas, so falling water still
// falls cell by cell in the Margolus kernel. Mass is integer-exact.
//
// The line is streamed (each run is read twice) rather than cached in a
// per-thread array, which would spill 128 registers and crawl.
//
// Voxel bytes: x = element id, y = seed, z = liquid amount, w bit 0 = the
// run is unsupported (falling), set by the column pass and used by the
// Margolus kernel to stop falling water from spraying sideways.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;

struct Elem {
	uint flags;
	float density;
	float decay;
	float spread;
	float extinction;
	float air_coupling;
	float heat;
	float smoothing;       // renderer: 0 crisp cubes .. 1 smooth heap
};
layout(std430, set = 0, binding = 1) restrict readonly buffer Elems { Elem elems[]; };

layout(push_constant, std430) uniform Params {
	uvec4 a; // mode, tick, seed, relax rate in percent
} pc;

layout(constant_id = 0) const int GRID = 128;
const uint AIR = 0u;
const uint FLAG_LIQUID = 1u << 2;
const uint FULL = 200u;
const uint MAX_AMOUNT = 255u;
const uint COMP = 2u;
const uint FLAG_GAS = 1u << 3;
const uint FALLING = 1u;

bool is_liquid(uint id) { return (elems[id].flags & FLAG_LIQUID) != 0u; }

ivec3 cell_at(int k) {
	uvec2 g = gl_GlobalInvocationID.xy;
	if (pc.a.x == 0u) {
		return ivec3(int(g.x), k, int(g.y));
	} else if (pc.a.x == 1u) {
		return ivec3(k, int(g.x), int(g.y));
	}
	return ivec3(int(g.x), int(g.y), k);
}

uvec4 load(int k) {
	return uvec4(imageLoad(grid, cell_at(k)) * 255.0 + 0.5);
}

void write(int k, uvec4 v, uint id, uint amount, uint w) {
	uvec4 nv = uvec4((amount == 0u) ? AIR : id, v.y, amount, (amount == 0u) ? 0u : w);
	if (nv != v) {
		imageStore(grid, cell_at(k), vec4(nv) / 255.0);
	}
}

// Hydrostatic profile for a run [s, e) of liquid L along y (s is the bottom).
void profile_column(int s, int e, uint L, uint M) {
	uint n = uint(e - s);
	// Resting on a solid, powder or other liquid? Air, gas or the floor below decide.
	uint w = 0u;
	if (s > 0) {
		uint under = load(s - 1).x;
		if (under == AIR || (elems[under].flags & FLAG_GAS) != 0u) {
			w = FALLING;
		}
	}
	// Largest H (full, compressed cells) that fits the mass.
	uint H = 0u;
	for (uint h = 1u; h <= n; h++) {
		if (h * FULL + COMP * h * (h - 1u) / 2u > M) {
			break;
		}
		H = h;
	}
	uint r = M - (H * FULL + COMP * H * (H - 1u) / 2u);
	uint extra_each = 0u, extra_rem = 0u;
	if (H == n) {
		// Every cell is full and compressed; spread the surplus as more compression.
		extra_each = r / n;
		extra_rem = r % n;
		r = 0u;
	}
	uint carry = 0u;
	for (uint k = 0u; k < n; k++) {
		uint want;
		if (k < H) {
			want = FULL + COMP * (H - 1u - k) + extra_each + ((k < extra_rem) ? 1u : 0u);
		} else if (k == H) {
			want = r;
		} else {
			want = 0u;
		}
		want += carry;
		carry = (want > MAX_AMOUNT) ? want - MAX_AMOUNT : 0u;
		want = min(want, MAX_AMOUNT);
		int idx = s + int(k);
		write(idx, load(idx), L, want, w);
	}
}

// Relax a horizontal run [s, e) toward its mean by pc.a.w percent, exactly.
void relax_row(int s, int e, uint L, uint M) {
	uint n = uint(e - s);
	float mean = float(M) / float(n);
	float rate = float(pc.a.w) / 100.0;
	// Rounding drift is paid back one unit per cell from the run start, so the
	// sum matches M exactly: first find the drift, then apply with correction.
	int drift = 0;
	for (int k = s; k < e; k++) {
		uint a = uint(load(k).z);
		int na = clamp(int(a) + int(round(rate * (mean - float(a)))), 1, int(MAX_AMOUNT));
		drift += na - int(a);
	}
	for (int k = s; k < e; k++) {
		uvec4 v = load(k);
		int na = clamp(int(v.z) + int(round(rate * (mean - float(v.z)))), 1, int(MAX_AMOUNT));
		if (drift > 0 && na > 1) { na--; drift--; }
		else if (drift < 0 && na < int(MAX_AMOUNT)) { na++; drift++; }
		write(k, v, L, uint(na), v.w);
	}
}

void main() {
	if (any(greaterThanEqual(gl_GlobalInvocationID.xy, uvec2(GRID)))) {
		return;
	}
	int k = 0;
	while (k < GRID) {
		uvec4 v = load(k);
		uint id = v.x;
		if (!is_liquid(id)) {
			k++;
			continue;
		}
		int s = k;
		uint M = 0u;
		while (k < GRID) {
			uvec4 w = (k == s) ? v : load(k);
			if (w.x != id) {
				break;
			}
			M += w.z;
			k++;
		}
		if (pc.a.x == 0u) {
			profile_column(s, k, id, M);
		} else if (k - s >= 2) {
			relax_row(s, k, id, M);
		}
	}
}
