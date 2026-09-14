#[compute]
#version 450

// Camera motion blur from depth alone (see scripts/environment/motion_blur.gd).
// The voxel world is static geometry whose motion vectors Godot cannot
// produce (the raymarch writes its own depth), so each pixel's velocity is
// reconstructed: depth -> world position -> where it was on screen last
// frame. Sprites get the camera's blur, which is what a shutter would show
// for the background anyway. 8 taps along the velocity, clamped in pixels.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Two dispatches: pass 0 blurs the frame (sampled) into a scratch image,
// pass 1 copies scratch back into the frame. The frame cannot be copied with
// texture_copy (no CAN_COPY_FROM usage) and cannot be read and written by
// neighbouring threads in one pass.
layout(set = 0, binding = 0) uniform sampler2D color_in;
layout(set = 0, binding = 1) uniform sampler2D depth_in;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D color_out;
layout(push_constant, std430) uniform Stage { ivec4 p; } stage; // x: 0 blur, 1 copy
layout(std140, set = 0, binding = 3) uniform Camera {
	mat4 inv_view_proj;   // current clip -> world
	mat4 prev_view_proj;  // world -> previous clip
	vec4 params;          // size x, size y, max blur px, strength
	vec4 flags;           // debug, unused
} cam;

const int TAPS = 8;

void main() {
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(cam.params.xy);
	if (any(greaterThanEqual(p, size))) {
		return;
	}
	vec4 col = texelFetch(color_in, p, 0);
	if (stage.p.x == 1) {
		imageStore(color_out, p, col);
		return;
	}
	vec2 uv = (vec2(p) + 0.5) / vec2(size);
	float depth = texelFetch(depth_in, p, 0).r;
	if (depth <= 0.0) {
		// Sky: no reconstruction, keep as is.
		imageStore(color_out, p, col);
		return;
	}
	vec4 ndc = vec4(uv * 2.0 - 1.0, depth, 1.0);
	vec4 world = cam.inv_view_proj * ndc;
	world /= world.w;
	vec4 prev = cam.prev_view_proj * world;
	prev.xy /= prev.w;
	vec2 vel_uv = (ndc.xy - prev.xy) * 0.5;   // this frame's movement in UV
	vec2 vel_px = vel_uv * vec2(size) * cam.params.w;
	float len = length(vel_px);
	if (len > cam.params.z) {
		vel_px *= cam.params.z / len;
		len = cam.params.z;
	}
	if (cam.flags.x > 0.5) {
		imageStore(color_out, p, vec4(abs(vel_px) / cam.params.z, len / cam.params.z, 1.0));
		return;
	}
	if (len < 0.5) {
		imageStore(color_out, p, col);
		return;
	}
	vec2 step_uv = vel_px / vec2(size) / float(TAPS);
	vec3 sum = col.rgb;
	float wsum = 1.0;
	for (int i = 1; i <= TAPS; i++) {
		float t = float(i) - 0.5 * float(TAPS);   // centred on the pixel
		vec2 suv = clamp(uv + step_uv * t, vec2(0.0), vec2(1.0));
		// Do not smear nearer geometry over what is behind it: taps whose depth
		// differs a lot from ours count less.
		float d = textureLod(depth_in, suv, 0.0).r;
		float w = 1.0 / (1.0 + 40.0 * abs(d - depth) / max(depth, 1e-4));
		sum += textureLod(color_in, suv, 0.0).rgb * w;
		wsum += w;
	}
	imageStore(color_out, p, vec4(sum / wsum, col.a));
}
