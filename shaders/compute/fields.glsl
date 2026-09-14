#[compute]
#version 450

// Renderer fields, one thread per voxel, written after every world change:
//   R = liquid density: fill remapped so trilinear sampling puts the 0.5
//       crossing exactly `fill` of the way up a partial cell on a full one;
//   G = smoothed opaque density: a symmetric 3^3 kernel over solids and
//       powders weighted by each element's `smooth`, so sand renders as a
//       smooth heap while walls (smooth 0) keep crisp faces. Flat surfaces keep
//       their 0.5 crossing exactly on the voxel boundary for any smoothing;
//   B = 1 for gas cells; A reserved (foam).
// The 8^3 workgroup stages a 10^3 neighbourhood in shared memory.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(rgba8, set = 0, binding = 1) uniform restrict writeonly image3D fields;

struct Elem {
	uint flags;
	float density;
	float decay;
	float spread;
	float extinction;
	float air_coupling;
	float heat;
	float smoothing;
};
layout(std430, set = 0, binding = 2) restrict readonly buffer Elems { Elem elems[]; };

layout(constant_id = 0) const int GRID = 128;

const uint FLAG_IMMOVABLE = 1u << 0;
const uint FLAG_POWDER = 1u << 1;
const uint FLAG_LIQUID = 1u << 2;
const uint FLAG_GAS = 1u << 3;
const float FULL = 200.0;
const int TILE = 10;

// Per staged cell: bit 0 opaque, bit 1 liquid, bits 8-15 smooth * 255,
// bits 16-23 liquid density * 255.
shared uint tile[TILE * TILE * TILE];

float liquid_density(uint amount) {
	float f = clamp(float(amount) / FULL, 0.0, 1.0);
	return (f < 0.5) ? f / (f + 0.5) : 0.5 / (1.5 - f);
}

int tidx(ivec3 l) { return l.x + TILE * (l.y + TILE * l.z); }

uint stage(ivec3 p) {
	if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(GRID)))) {
		return 0u;
	}
	uvec4 v = uvec4(imageLoad(grid, p) * 255.0 + 0.5);
	uint id = v.x;
	if (id == 0u) {
		return 0u;
	}
	uint flags = elems[id].flags;
	if ((flags & FLAG_LIQUID) != 0u) {
		return 2u | (uint(liquid_density(v.z) * 255.0 + 0.5) << 16);
	}
	if ((flags & (FLAG_IMMOVABLE | FLAG_POWDER)) == 0u) {
		return 0u;
	}
	return 1u | (uint(clamp(elems[id].smoothing, 0.0, 1.0) * 255.0 + 0.5) << 8);
}

float weight(int manhattan) {
	return (manhattan == 0) ? 0.52 : ((manhattan == 1) ? 0.05 : ((manhattan == 2) ? 0.0125 : 0.00375));
}

void main() {
	ivec3 base = ivec3(gl_WorkGroupID) * 8 - 1;
	for (uint i = gl_LocalInvocationIndex; i < uint(TILE * TILE * TILE); i += 512u) {
		ivec3 l = ivec3(int(i) % TILE, (int(i) / TILE) % TILE, int(i) / (TILE * TILE));
		tile[i] = stage(base + l);
	}
	barrier();

	ivec3 p = ivec3(gl_GlobalInvocationID);
	ivec3 l = ivec3(gl_LocalInvocationID) + 1;
	uint me = tile[tidx(l)];
	float occ_me = float(me & 1u);
	float sm_me = float(me >> 8) / 255.0;

	float smooth_sum = 0.0;
	for (int dz = -1; dz <= 1; dz++) {
		for (int dy = -1; dy <= 1; dy++) {
			for (int dx = -1; dx <= 1; dx++) {
				uint e = tile[tidx(l + ivec3(dx, dy, dz))];
				float w = weight(abs(dx) + abs(dy) + abs(dz));
				smooth_sum += w * float(e & 1u) * (float(e >> 8) / 255.0);
			}
		}
	}
	float g = max(occ_me * (1.0 - sm_me), smooth_sum);

	float r = 0.0;
	float b = 0.0;
	if ((me & 2u) != 0u) {
		// Liquid: average the density over same-layer liquid neighbours so thin
		// films with per-cell fill jitter render as one smooth sheet.
		float own = float(me >> 16) / 255.0;
		float sum = 0.5 * own;
		float wsum = 0.5;
		for (int dz = -1; dz <= 1; dz++) {
			for (int dx = -1; dx <= 1; dx++) {
				if (dx == 0 && dz == 0) { continue; }
				uint e = tile[tidx(l + ivec3(dx, 0, dz))];
				float w = (abs(dx) + abs(dz) == 1) ? 0.1 : 0.025;
				sum += w * (((e & 2u) != 0u) ? float(e >> 16) / 255.0 : own);
				wsum += w;
			}
		}
		r = sum / wsum;
	} else if ((me & 1u) != 0u) {
		r = 1.0; // solids bound the liquid surface too
	} else {
		uint id = uint(imageLoad(grid, p).r * 255.0 + 0.5);
		if (id != 0u && (elems[id].flags & FLAG_GAS) != 0u) {
			b = 1.0;
		}
	}
	imageStore(fields, p, vec4(r, g, b, 0.0));
}
