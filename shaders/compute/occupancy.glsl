#[compute]
#version 450

// Coarse occupancy: one thread per 8x8x8 brick of the voxel world.
// R = 1 if the brick holds any solid or powder, G = 1 if it holds any liquid
// or gas. The opaque and volume raymarch passes each leap over bricks empty
// in their own channel.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(rgba8, set = 0, binding = 1) uniform restrict writeonly image3D occupancy;

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
layout(std430, set = 0, binding = 2) restrict readonly buffer Elems { Elem elems[]; };

const int BRICK = 8;
const uint FLAG_LIQUID = 1u << 2;
const uint FLAG_GAS = 1u << 3;

void main() {
	ivec3 brick = ivec3(gl_GlobalInvocationID);
	ivec3 base = brick * BRICK;
	bool solid = false;
	bool fluid = false;
	for (int z = 0; z < BRICK && !(solid && fluid); z++) {
		for (int y = 0; y < BRICK && !(solid && fluid); y++) {
			for (int x = 0; x < BRICK; x++) {
				uint id = uint(imageLoad(grid, base + ivec3(x, y, z)).r * 255.0 + 0.5);
				if (id == 0u) {
					continue;
				}
				if ((elems[id].flags & (FLAG_LIQUID | FLAG_GAS)) != 0u) {
					fluid = true;
				} else {
					solid = true;
				}
			}
		}
	}
	imageStore(occupancy, brick, vec4(solid ? 1.0 : 0.0, fluid ? 1.0 : 0.0, 0.0, 0.0));
}
