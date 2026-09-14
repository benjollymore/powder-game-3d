#[compute]
#version 450

// Coarse occupancy: one thread per 8x8x8 brick of the voxel world, writes 1
// if the brick holds anything that is not air or gas, else 0. Used by the
// raymarcher to skip empty space and by the shadow proxy on the CPU.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(r8, set = 0, binding = 1) uniform restrict writeonly image3D occupancy;

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
const uint FLAG_GAS = 1u << 3;

void main() {
	ivec3 brick = ivec3(gl_GlobalInvocationID);
	ivec3 base = brick * BRICK;
	bool solid = false;
	for (int z = 0; z < BRICK && !solid; z++) {
		for (int y = 0; y < BRICK && !solid; y++) {
			for (int x = 0; x < BRICK; x++) {
				uint id = uint(imageLoad(grid, base + ivec3(x, y, z)).r * 255.0 + 0.5);
				if (id != 0u && (elems[id].flags & FLAG_GAS) == 0u) {
					solid = true;
					break;
				}
			}
		}
	}
	imageStore(occupancy, brick, vec4(solid ? 1.0 : 0.0));
}
