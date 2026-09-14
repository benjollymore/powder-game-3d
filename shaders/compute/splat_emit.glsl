#[compute]
#version 450

// Collects airborne grains (powder cells that moved recently and have nothing
// under them) into a MultiMesh instance buffer as camera-facing splats. One
// thread per voxel; a workgroup covers one 8^3 brick and exits early when the
// occupancy grid says it holds no solids or powders.
//
// MultiMesh 3D instance layout (use_custom_data, no colours): 16 floats:
// rows of the 3x4 transform (xx xy xz ox / yx yy yz oy / zx zy zz oz) then
// the custom vec4 as plain floats. Instances are in the sim volume's model
// space (unit box).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(rgba8, set = 0, binding = 1) uniform restrict readonly image3D occupancy;

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
layout(std430, set = 0, binding = 3) buffer Counter { uint count; uint pad[3]; } counter;
layout(std430, set = 0, binding = 4) restrict writeonly buffer Instances { float data[]; } inst;

layout(push_constant, std430) uniform Params {
	uvec4 a; // capacity, unused
} pc;

layout(constant_id = 0) const int GRID = 128;

const uint FLAG_POWDER = 1u << 1;
const uint FLAG_GAS = 1u << 3;

uint id_at(ivec3 p) {
	if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(GRID)))) {
		return 1u; // outside is wall
	}
	return uint(imageLoad(grid, p).r * 255.0 + 0.5);
}

bool open(uint id) {
	return id == 0u || (elems[id].flags & FLAG_GAS) != 0u;
}

void main() {
	ivec3 brick = ivec3(gl_WorkGroupID);
	if (imageLoad(occupancy, brick).r < 0.5) {
		return;
	}
	ivec3 p = ivec3(gl_GlobalInvocationID);
	uvec4 v = uvec4(imageLoad(grid, p) * 255.0 + 0.5);
	uint id = v.x;
	if (id == 0u || (elems[id].flags & FLAG_POWDER) == 0u) {
		return;
	}
	uint age = (v.w >> 1) & 3u;
	if (age == 0u || !open(id_at(p - ivec3(0, 1, 0)))) {
		return;
	}
	uint idx = atomicAdd(counter.count, 1u);
	if (idx >= pc.a.x) {
		return;
	}
	float g = float(GRID);
	// Per-grain jitter from the seed byte hides the voxel lattice in a falling stream.
	uint h = v.y * 2654435761u ^ uint(p.x * 73856093 ^ p.y * 19349663 ^ p.z * 83492791);
	vec3 jitter = (vec3(float(h & 255u), float((h >> 8) & 255u), float((h >> 16) & 255u)) / 255.0 - 0.5) * 0.7;
	vec3 origin = (vec3(p) + 0.5 + jitter) / g - 0.5;
	float size = (0.8 + 0.5 * float((h >> 24) & 255u) / 255.0) / g;
	uint base = idx * 16u;
	inst.data[base + 0] = size; inst.data[base + 1] = 0.0;  inst.data[base + 2] = 0.0;  inst.data[base + 3] = origin.x;
	inst.data[base + 4] = 0.0;  inst.data[base + 5] = size; inst.data[base + 6] = 0.0;  inst.data[base + 7] = origin.y;
	inst.data[base + 8] = 0.0;  inst.data[base + 9] = 0.0;  inst.data[base + 10] = size; inst.data[base + 11] = origin.z;
	inst.data[base + 12] = float(id);
	inst.data[base + 13] = float(v.y) / 255.0;
	inst.data[base + 14] = float(age);
	inst.data[base + 15] = 0.0;
}
