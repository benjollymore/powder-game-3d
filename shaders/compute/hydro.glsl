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
// Heat travels with the liquid (docs/milestone/thermal-physics.md): the
// accepted integer amounts define a monotone mass-coordinate remap of each
// run's energy, so parcels keep their order along the line and a hot bottom
// stays a hot bottom. The remap is exact for any run length because it is
// done in three stages, each its own dispatch (pc.b.x), so no invocation
// ever reads a texel it wrote itself (a same-thread read after an image
// write is not coherent on the Metal backend): stage 0 folds each cell's
// latent progress into one energy value, stage 1 walks the receivers and
// reads donors from data only earlier dispatches wrote, stage 2 writes the
// new amounts and temperatures. Amounts are recomputed identically in each
// stage from the untouched grid.
//
// Voxel bytes: x = element id, y = seed, z = liquid amount, w bit 0 = the
// run is unsupported (falling), set by the column pass and used by the
// Margolus kernel to stop falling water from spraying sideways.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;

#include "elem.glslinc"
layout(std430, set = 0, binding = 1) restrict readonly buffer Elems { Elem elems[]; };
layout(rg32f, set = 0, binding = 2) uniform restrict image3D thermal;
#include "thermal_common.glslinc"

layout(push_constant, std430) uniform Params {
	uvec4 a; // mode, tick, seed, relax rate in percent
	uvec4 b; // remap stage (0 fold, 1 receive, 2 finish and write amounts), unused
} pc;

layout(constant_id = 0) const int GRID = 128;
const uint AIR = 0u;
const uint FLAG_LIQUID = 1u << 2;
const uint FULL = 200u;
const uint MAX_AMOUNT = 255u;
const uint COMP = 2u;
const uint FLAG_GAS = 1u << 3;
const uint FALLING = 1u;
// Heat capacity is exactly linear in amount (runs hold liquid cells with at
// least one unit); the remap moves energy proportionally to units. Keep in
// sync with sim.glsl and VoxelSim.energy_total.

// Donor cursor of the running remap.
int rd;
int run_end;
uint rd_amount;
uint rd_rem;
float rd_energy;
float rd_sent;

bool is_liquid(uint id) { return (elems[id].flags & FLAG_LIQUID) != 0u; }

float cell_capacity(uint id, uint amount) {
	float cap = ELEM_HEAT_CAPACITY(elems[id]);
	if (amount > 0u) {
		cap *= float(amount) / float(FULL);
	}
	return cap;
}

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

vec2 read_thermal(int k) {
	return imageLoad(thermal, cell_at(k)).rg;
}

void write(int k, uvec4 v, uint id, uint amount, uint w) {
	uvec4 nv = uvec4((amount == 0u) ? AIR : id, v.y, amount, (amount == 0u) ? 0u : w);
	if (nv != v) {
		imageStore(grid, cell_at(k), vec4(nv) / 255.0);
	}
}

void write_thermal(int k, vec2 old, vec2 nv) {
	if (nv != old) {
		imageStore(thermal, cell_at(k), vec4(nv, 0.0, 0.0));
	}
}

// --- monotone mass-coordinate energy remap ----------------------------------

// Sweep 0: fold latent progress into one energy value per cell, kept in R
// with G cleared, so sweep 1 can read a cell's whole energy from one channel.
void remap_fold(int s, int e, uint L) {
	for (int k = s; k < e; k++) {
		uvec4 v = load(k);
		vec2 tg = read_thermal(k);
		float E = cell_capacity(L, v.z) * tg.x + tg.y;
		write_thermal(k, tg, vec2(E, 0.0));
	}
}

void remap_begin(int s, int e) {
	rd = s - 1;
	run_end = e;
	rd_amount = 0u;
	rd_rem = 0u;
	rd_energy = 0.0;
	rd_sent = 0.0;
}

// Sweep 1: the energy cell k receives when it will hold `new_amount` units,
// from the earliest donors whose mass has not been assigned yet, in
// proportion to the units taken (a donor's last units carry its remainder,
// so nothing is lost to rounding). Donors are read from the grid's amounts
// and the R channel, which this sweep never writes; the result goes into G.
void remap_receive(int k, uint L, uint new_amount) {
	uint need = new_amount;
	float E_new = 0.0;
	while (need > 0u) {
		if (rd_rem == 0u) {
			rd++;
			if (rd >= run_end) { break; }
			rd_amount = load(rd).z;
			rd_energy = imageLoad(thermal, cell_at(rd)).r;
			rd_rem = rd_amount;
			rd_sent = 0.0;
			if (rd_rem == 0u) { continue; }
		}
		uint units = min(rd_rem, need);
		float q = (units == rd_rem) ? (rd_energy - rd_sent) : rd_energy * (float(units) / float(rd_amount));
		E_new += q;
		rd_sent += q;
		rd_rem -= units;
		need -= units;
	}
	float E_old = imageLoad(thermal, cell_at(k)).r;
	imageStore(thermal, cell_at(k), vec4(E_old, E_new, 0.0, 0.0));
}

// Sweep 2: the thermal state to write beside the new amount. The air left
// behind by an emptied cell keeps its temperature; anything else settles on
// its received energy.
vec2 remap_finish(int k, uint L, uint old_amount, uint new_amount) {
	vec2 e = read_thermal(k); // R = old energy, G = new energy
	if (new_amount == 0u) {
		return vec2(e.x / cell_capacity(L, old_amount), 0.0);
	}
	float C = cell_capacity(L, new_amount);
	return settle(vec2(e.y / C, 0.0), C, ELEM_HOT_AT(elems[L]), ELEM_COLD_AT(elems[L]));
}

// --- passes -------------------------------------------------------------------

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
	uint stage = pc.b.x;
	if (stage == 0u) {
		remap_fold(s, e, L);
		return;
	}
	remap_begin(s, e);
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
		if (stage == 1u) {
			remap_receive(idx, L, want);
			continue;
		}
		uvec4 v = load(idx);
		vec2 ntg = remap_finish(idx, L, v.z, want);
		// Bits 1-2: "landed" age, set to 3 the tick a falling run comes to rest,
		// counting down after (splash and foam triggers for the renderer).
		uint landed = (v.w >> 1) & 3u;
		if ((v.w & FALLING) != 0u && w == 0u) {
			landed = 3u;
		} else if (landed > 0u) {
			landed -= 1u;
		}
		write(idx, v, L, want, w | (landed << 1));
		imageStore(thermal, cell_at(idx), vec4(ntg, 0.0, 0.0));
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
	uint stage = pc.b.x;
	if (stage == 0u) {
		remap_fold(s, e, L);
		return;
	}
	remap_begin(s, e);
	for (int k = s; k < e; k++) {
		uvec4 v = load(k);
		int na = clamp(int(v.z) + int(round(rate * (mean - float(v.z)))), 1, int(MAX_AMOUNT));
		if (drift > 0 && na > 1) { na--; drift--; }
		else if (drift < 0 && na < int(MAX_AMOUNT)) { na++; drift++; }
		if (stage == 1u) {
			remap_receive(k, L, uint(na));
			continue;
		}
		vec2 ntg = remap_finish(k, L, v.z, uint(na));
		write(k, v, L, uint(na), v.w);
		imageStore(thermal, cell_at(k), vec4(ntg, 0.0, 0.0));
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
