#[compute]
#version 450

// Liquid density field for the renderer, one thread per voxel. Sampled with
// trilinear filtering so liquids can be drawn as a smooth 0.5 isosurface:
//   gases and air -> 0, solids and powders -> 1 (the surface meets walls),
//   liquids -> remap(fill) so that a partial cell resting on a full cell puts
//   the 0.5 crossing exactly `fill` of the way up the cell, and thin films do
//   not vanish under interpolation.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(r8, set = 0, binding = 1) uniform restrict writeonly image3D density;

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
layout(std430, set = 0, binding = 2) restrict readonly buffer Elems { Elem elems[]; };

const uint FLAG_LIQUID = 1u << 2;
const uint FLAG_GAS = 1u << 3;
const float FULL = 200.0;

void main() {
	ivec3 p = ivec3(gl_GlobalInvocationID);
	uvec4 v = uvec4(imageLoad(grid, p) * 255.0 + 0.5);
	uint id = v.x;
	float d = 0.0;
	if (id != 0u) {
		uint flags = elems[id].flags;
		if ((flags & FLAG_LIQUID) != 0u) {
			float f = clamp(float(v.z) / FULL, 0.0, 1.0);
			d = (f < 0.5) ? f / (f + 0.5) : 0.5 / (1.5 - f);
		} else if ((flags & FLAG_GAS) == 0u) {
			d = 1.0;
		}
	}
	imageStore(density, p, vec4(d));
}
