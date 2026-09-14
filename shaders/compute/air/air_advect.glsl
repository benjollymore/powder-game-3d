#[compute]
#version 450

// Air solver, pass 2: semi-Lagrangian advection of velocity and heat, plus
// buoyancy from heat, drag, and a speed clamp. Solid cells hold zero velocity.
// Velocity is in voxels per tick; the grid is AIR_GRID cells of SUB voxels.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(set = 0, binding = 0) uniform sampler3D vel_in;
layout(r8, set = 0, binding = 1) uniform restrict readonly image3D occ;
layout(rgba16f, set = 0, binding = 2) uniform restrict readonly image3D src;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D vel_out;

layout(push_constant, std430) uniform Params {
	vec4 p;  // dt (ticks), buoyancy, drag per tick, max speed
	uvec4 m; // tick, unused
} pc;

layout(constant_id = 0) const int AIR_GRID_I = 32;
layout(constant_id = 1) const int SUB_I = 4;

void main() {
	ivec3 c = ivec3(gl_GlobalInvocationID);
	float AIR_GRID = float(AIR_GRID_I);
	float SUB = float(SUB_I);
	float dt = pc.p.x;
	vec4 s = imageLoad(src, c);
	if (imageLoad(occ, c).r > 0.5) {
		imageStore(vel_out, c, vec4(0.0, 0.0, 0.0, s.w));
		return;
	}
	vec3 pos = vec3(c) + 0.5;
	vec3 u_here = texture(vel_in, pos / AIR_GRID).xyz;
	vec3 back = pos - u_here * dt / SUB;
	vec4 prev = texture(vel_in, back / AIR_GRID);
	vec3 u = prev.xyz;
	float heat = prev.w * pow(0.97, dt) + s.w * dt * 0.5;
	heat = min(heat, 2.0);
	u.y += pc.p.y * heat * dt;
	u *= pow(1.0 - pc.p.z, dt);
	float len = length(u);
	if (len > pc.p.w) {
		u *= pc.p.w / len;
	}
	imageStore(vel_out, c, vec4(u, heat));
}
