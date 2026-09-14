#[compute]
#version 450

// Air solver, pass 1: summarise each 4x4x4 voxel cell of the coarse air grid:
// solid fraction (walls, powders, liquid by fill) for boundaries, and heat
// (fire, steam) that drives buoyancy.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(r8, set = 0, binding = 1) uniform restrict writeonly image3D occ;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image3D src;

struct Elem {
	uint flags;
	float density;
	float decay;
	float spread;
	float extinction;
	float air_coupling;
	float heat;
	float pad;
};
layout(std430, set = 0, binding = 3) restrict readonly buffer Elems { Elem elems[]; };


layout(push_constant, std430) uniform Params {
	vec4 p;  // dt (ticks), buoyancy, drag per tick, max speed
	uvec4 m; // tick, unused
} pc;

const int SUB = 4;
const uint FLAG_IMMOVABLE = 1u << 0;
const uint FLAG_POWDER = 1u << 1;
const uint FLAG_LIQUID = 1u << 2;
const float FULL = 200.0;

void main() {
	if (pc.m.w == 0xFFFFFFFFu) { return; } // keeps the shared push-constant block alive
	ivec3 c = ivec3(gl_GlobalInvocationID);
	ivec3 base = c * SUB;
	float solid = 0.0;
	float heat = 0.0;
	for (int z = 0; z < SUB; z++) {
		for (int y = 0; y < SUB; y++) {
			for (int x = 0; x < SUB; x++) {
				uvec4 v = uvec4(imageLoad(grid, base + ivec3(x, y, z)) * 255.0 + 0.5);
				uint id = v.x;
				if (id == 0u) {
					continue;
				}
				uint flags = elems[id].flags;
				if ((flags & (FLAG_IMMOVABLE | FLAG_POWDER)) != 0u) {
					solid += 1.0;
				} else if ((flags & FLAG_LIQUID) != 0u) {
					solid += min(float(v.z) / FULL, 1.0);
				}
				heat += elems[id].heat;
			}
		}
	}
	imageStore(occ, c, vec4(solid / 64.0));
	imageStore(src, c, vec4(0.0, 0.0, 0.0, heat / 64.0));
}
