#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;
layout(std430, set = 0, binding = 1) buffer Bytes { uint values[]; } data;
// Authoritative thermal layer: R temperature (K), G latent progress. A region
// record carries both layers so history restores every authoritative byte.
layout(rg32f, set = 0, binding = 2) uniform restrict image3D thermal;
layout(push_constant, std430) uniform Params {
    ivec4 lo_mode; // mode 0 extracts exact packed voxels, mode 1 restores them
    ivec4 size_offset; // offset in uints
} pc;
// Record layout per region, in uints: n packed voxels, then 2n thermal floats
// (temperature bits, latent bits per cell, same cell order). 12 bytes per cell.
void main() {
    ivec3 p = ivec3(gl_GlobalInvocationID);
    ivec3 size = pc.size_offset.xyz;
    if (any(greaterThanEqual(p, size))) { return; }
    int n = size.x * size.y * size.z;
    int idx = p.x + size.x * (p.y + size.y * p.z);
    int base = pc.size_offset.w;
    if (pc.lo_mode.w == 0) {
        uvec4 v = uvec4(imageLoad(grid, pc.lo_mode.xyz + p) * 255.0 + 0.5);
        data.values[base + idx] = v.r | (v.g << 8) | (v.b << 16) | (v.a << 24);
        vec2 t = imageLoad(thermal, pc.lo_mode.xyz + p).rg;
        data.values[base + n + 2 * idx] = floatBitsToUint(t.r);
        data.values[base + n + 2 * idx + 1] = floatBitsToUint(t.g);
    } else {
        uint v = data.values[base + idx];
        imageStore(grid, pc.lo_mode.xyz + p, vec4(uvec4(v, v >> 8, v >> 16, v >> 24) & 255u) / 255.0);
        float tr = uintBitsToFloat(data.values[base + n + 2 * idx]);
        float tg = uintBitsToFloat(data.values[base + n + 2 * idx + 1]);
        imageStore(thermal, pc.lo_mode.xyz + p, vec4(tr, tg, 0.0, 0.0));
    }
}
