#[compute]
#version 450

// Box-filter one mip level of the fields texture into the next. The mips feed
// ambient occlusion cone taps in the renderer.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D src;
layout(rgba8, set = 0, binding = 1) uniform restrict writeonly image3D dst;

layout(push_constant, std430) uniform Params {
	uvec4 size; // destination mip size, unused
} pc;

void main() {
	ivec3 p = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(p, ivec3(pc.size.xyz)))) {
		return;
	}
	vec4 sum = vec4(0.0);
	for (int k = 0; k < 8; k++) {
		sum += imageLoad(src, p * 2 + ivec3(k & 1, (k >> 1) & 1, (k >> 2) & 1));
	}
	imageStore(dst, p, sum / 8.0);
}
