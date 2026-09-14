#[compute]
#version 450

// Paints a sphere (modes 0-2) or an axis-aligned box (mode 3) of one element
// into the voxel world. Dispatched over the bounding box; one thread per voxel.
// Box mode is how scenarios are built on the GPU.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;

layout(push_constant, std430) uniform Params {
	ivec4 center_radius;      // sphere: cx, cy, cz, radius (voxels); box: lo xyz, unused
	uvec4 element_mode_seed;  // element id, mode (0 replace, 1 only into air, 2 erase, 3 box), seed, liquid amount
	ivec4 box_hi;             // box: exclusive upper corner
} pc;

layout(constant_id = 0) const int GRID = 128;

uint hash(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

void main() {
	uint mode = pc.element_mode_seed.y;
	ivec3 lo = (mode >= 3u) ? pc.center_radius.xyz : pc.center_radius.xyz - ivec3(pc.center_radius.w);
	ivec3 p = lo + ivec3(gl_GlobalInvocationID);
	if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(GRID)))) {
		return;
	}
	if (mode >= 3u) {
		if (any(greaterThanEqual(p, pc.box_hi.xyz))) {
			return;
		}
	} else {
		ivec3 d = p - pc.center_radius.xyz;
		int r = pc.center_radius.w;
		if (dot(d, d) > r * r) {
			return;
		}
	}
	uint id = pc.element_mode_seed.x;
	if (mode == 2u) {
		id = 0u;
	} else if (mode == 1u || mode == 4u) {
		uvec4 cur = uvec4(imageLoad(grid, p) * 255.0 + 0.5);
		if (cur.x != 0u) {
			return;
		}
	}
	uint seed = hash(uint(p.x) * 73856093u ^ uint(p.y) * 19349663u ^ uint(p.z) * 83492791u
			^ pc.element_mode_seed.z) & 0xFFu;
	uint amount = (mode == 2u) ? 0u : pc.element_mode_seed.w;
	imageStore(grid, p, vec4(uvec4(id, seed, amount, 0u)) / 255.0);
}
