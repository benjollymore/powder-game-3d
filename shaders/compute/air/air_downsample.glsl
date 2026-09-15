#[compute]
#version 450

// Air solver, pass 1: summarise each 4x4x4 voxel cell of the coarse air grid:
// solid fraction (walls, powders, liquid by fill) for boundaries, and heat
// that drives buoyancy. Heat is the excess temperature of air and gas cells
// over ambient (thermal layer), so a fire plume, hot smoke or a cloud of
// steam rises because it is hot, not because of a per-element constant.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(r8, set = 0, binding = 1) uniform restrict writeonly image3D occ;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image3D src;

#include "../elem.glslinc"
layout(std430, set = 0, binding = 3) restrict readonly buffer Elems { Elem elems[]; };
layout(rg32f, set = 0, binding = 4) uniform restrict readonly image3D thermal;


layout(push_constant, std430) uniform Params {
	vec4 p;  // dt (ticks), buoyancy, drag per tick, max speed
	uvec4 m; // tick, ambient temperature (float bits), thermal subsample stride (1 = every voxel), unused
} pc;

layout(constant_id = 0) const int AIR_GRID = 32;
layout(constant_id = 1) const int SUB = 4;
const uint FLAG_IMMOVABLE = 1u << 0;
const uint FLAG_POWDER = 1u << 1;
const uint FLAG_LIQUID = 1u << 2;
const uint FLAG_GAS = 1u << 3;
const float FULL = 200.0;
// Excess kelvin that counts as one unit of buoyancy source: fire at 1200 K
// contributes about 2.3 (advection caps the field at 2), steam at 380 K 0.2
// and smoke at 400 K 0.27, close to the former per-element constants.
const float HEAT_SCALE = 400.0;

void main() {
	if (pc.m.w == 0xFFFFFFFFu) { return; } // keeps the shared push-constant block alive
	ivec3 c = ivec3(gl_GlobalInvocationID);
	ivec3 base = c * SUB;
	float ambient = uintBitsToFloat(pc.m.y);
	// Cost variant: read the thermal layer at every stride-th voxel per axis
	// and weight it by the skipped volume (the 32^3 source is coarse anyway).
	int stride = max(int(pc.m.z), 1);
	float weight = float(stride * stride * stride);
	float solid = 0.0;
	float heat = 0.0;
	for (int z = 0; z < SUB; z++) {
		for (int y = 0; y < SUB; y++) {
			for (int x = 0; x < SUB; x++) {
				ivec3 p = base + ivec3(x, y, z);
				uvec4 v = uvec4(imageLoad(grid, p) * 255.0 + 0.5);
				uint id = v.x;
				uint flags = id == 0u ? FLAG_GAS : elems[id].flags;
				if ((flags & (FLAG_IMMOVABLE | FLAG_POWDER)) != 0u) {
					solid += 1.0;
				} else if ((flags & FLAG_LIQUID) != 0u) {
					solid += min(float(v.z) / FULL, 1.0);
				}
				if ((flags & FLAG_GAS) != 0u && (x % stride) == 0 && (y % stride) == 0 && (z % stride) == 0) {
					heat += weight * max(0.0, imageLoad(thermal, p).r - ambient) / HEAT_SCALE;
				}
			}
		}
	}
	float n = float(SUB * SUB * SUB);
	imageStore(occ, c, vec4(solid / n));
	imageStore(src, c, vec4(0.0, 0.0, 0.0, heat / n));
}
