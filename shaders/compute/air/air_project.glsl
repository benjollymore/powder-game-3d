#[compute]
#version 450

// Air solver, pass 5: subtract the pressure gradient so the field is (nearly)
// divergence free, and zero any component pointing into a solid neighbour.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image3D vel_in;
layout(r16f, set = 0, binding = 1) uniform restrict readonly image3D pres;
layout(r8, set = 0, binding = 2) uniform restrict readonly image3D occ;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D vel_out;


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

float p_at(ivec3 q, float pc_) {
	return solid(q) ? pc_ : imageLoad(pres, q).r;
}

void main() {
	if (pc.m.w == 0xFFFFFFFFu) { return; } // keeps the shared push-constant block alive
	ivec3 c = ivec3(gl_GlobalInvocationID);
	vec4 v = imageLoad(vel_in, c);
	if (solid(c)) {
		imageStore(vel_out, c, vec4(0.0, 0.0, 0.0, v.w));
		return;
	}
	float pc_ = imageLoad(pres, c).r;
	vec3 grad = 0.5 * vec3(
		p_at(c + ivec3(1, 0, 0), pc_) - p_at(c - ivec3(1, 0, 0), pc_),
		p_at(c + ivec3(0, 1, 0), pc_) - p_at(c - ivec3(0, 1, 0), pc_),
		p_at(c + ivec3(0, 0, 1), pc_) - p_at(c - ivec3(0, 0, 1), pc_));
	vec3 u = v.xyz - grad;
	if (solid(c + ivec3(1, 0, 0)) && u.x > 0.0) { u.x = 0.0; }
	if (solid(c - ivec3(1, 0, 0)) && u.x < 0.0) { u.x = 0.0; }
	if (solid(c + ivec3(0, 1, 0)) && u.y > 0.0) { u.y = 0.0; }
	if (solid(c - ivec3(0, 1, 0)) && u.y < 0.0) { u.y = 0.0; }
	if (solid(c + ivec3(0, 0, 1)) && u.z > 0.0) { u.z = 0.0; }
	if (solid(c - ivec3(0, 0, 1)) && u.z < 0.0) { u.z = 0.0; }
	imageStore(vel_out, c, vec4(u, v.w));
}
