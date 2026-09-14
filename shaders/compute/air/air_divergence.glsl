#[compute]
#version 450

// Air solver, pass 3: divergence of the advected velocity. Solid neighbours
// and the box walls contribute zero normal flow.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image3D vel;
layout(r8, set = 0, binding = 1) uniform restrict readonly image3D occ;
layout(r16f, set = 0, binding = 2) uniform restrict writeonly image3D div;


layout(push_constant, std430) uniform Params {
	vec4 p;  // dt (ticks), buoyancy, drag per tick, max speed
	uvec4 m; // tick, unused
} pc;

const int AIR_GRID = 32;

bool solid(ivec3 p) {
	if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(AIR_GRID)))) {
		return true;
	}
	return imageLoad(occ, p).r > 0.5;
}

vec3 vel_at(ivec3 p) {
	return solid(p) ? vec3(0.0) : imageLoad(vel, p).xyz;
}

void main() {
	if (pc.m.w == 0xFFFFFFFFu) { return; } // keeps the shared push-constant block alive
	ivec3 c = ivec3(gl_GlobalInvocationID);
	float d = 0.0;
	if (!solid(c)) {
		d = 0.5 * ((vel_at(c + ivec3(1, 0, 0)).x - vel_at(c - ivec3(1, 0, 0)).x)
				+ (vel_at(c + ivec3(0, 1, 0)).y - vel_at(c - ivec3(0, 1, 0)).y)
				+ (vel_at(c + ivec3(0, 0, 1)).z - vel_at(c - ivec3(0, 0, 1)).z));
	}
	imageStore(div, c, vec4(d));
}
