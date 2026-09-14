#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;
layout(std430, set = 0, binding = 1) buffer Bytes { uint values[]; } data;
layout(push_constant, std430) uniform Params {
    ivec4 lo_mode; // mode 0 extracts exact packed voxels, mode 1 restores them
    ivec4 size_offset; // offset in uints
} pc;
void main() {
    ivec3 p = ivec3(gl_GlobalInvocationID);
    ivec3 size = pc.size_offset.xyz;
    if (any(greaterThanEqual(p, size))) { return; }
    int i = pc.size_offset.w + p.x + size.x * (p.y + size.y * p.z);
    if (pc.lo_mode.w == 0) {
        uvec4 v = uvec4(imageLoad(grid, pc.lo_mode.xyz + p) * 255.0 + 0.5);
        data.values[i] = v.r | (v.g << 8) | (v.b << 16) | (v.a << 24);
    } else {
        uint v = data.values[i];
        imageStore(grid, pc.lo_mode.xyz + p, vec4(uvec4(v, v >> 8, v >> 16, v >> 24) & 255u) / 255.0);
    }
}
