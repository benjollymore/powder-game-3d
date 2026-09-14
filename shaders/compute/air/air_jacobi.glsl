#[compute]
#version 450

// Air solver, pass 4 (repeated): one Jacobi iteration of the pressure Poisson
// equation with Neumann boundaries at solids and the box walls.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(r16f, set = 0, binding = 0) uniform restrict readonly image3D pres_in;
layout(r16f, set = 0, binding = 1) uniform restrict readonly image3D div;
layout(r8, set = 0, binding = 2) uniform restrict readonly image3D occ;
layout(r16f, set = 0, binding = 3) uniform restrict writeonly image3D pres_out;


layout(push_constant, std430) uniform Params {
	vec4 p;  // dt (ticks), buoyancy, drag per tick, max speed
	uvec4 m; // tick, unused
} pc;

layout(constant_id = 0) const int AIR_GRID = 32;
layout(constant_id = 1) const int SUB = 4;

bool solid(ivec3 p) {
	if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(AIR_GRID)))) {
		return true;
	}
	return imageLoad(occ, p).r > 0.5;
}

void main() {
	if (pc.m.w == 0xFFFFFFFFu) { return; } // keeps the shared push-constant block alive
	ivec3 c = ivec3(gl_GlobalInvocationID);
	float pc_ = imageLoad(pres_in, c).r;
	float sum = 0.0;
	const ivec3 n[6] = ivec3[6](ivec3(1, 0, 0), ivec3(-1, 0, 0), ivec3(0, 1, 0), ivec3(0, -1, 0), ivec3(0, 0, 1), ivec3(0, 0, -1));
	for (int k = 0; k < 6; k++) {
		ivec3 q = c + n[k];
		sum += solid(q) ? pc_ : imageLoad(pres_in, q).r;
	}
	float p = (sum - imageLoad(div, c).r) / 6.0;
	imageStore(pres_out, c, vec4(solid(c) ? 0.0 : p));
}
