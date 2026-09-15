#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;
layout(std430, set = 0, binding = 1) readonly buffer Result {
    ivec4 hit; ivec4 normal; ivec4 target; ivec4 stats;
} pick;
// Painted material starts at its element's initial temperature; an erased
// cell keeps its temperature (the air left behind inherits it).
layout(rg32f, set = 0, binding = 2) uniform restrict image3D thermal;
#include "../elem.glslinc"
layout(std430, set = 0, binding = 3) restrict readonly buffer Elems { Elem elems[]; };
layout(push_constant, std430) uniform Params {
    ivec4 brush; // grid size, radius, element, mode (ONLY_AIR/ERASE)
    ivec4 material; // seed, initial liquid amount, unused, unused
} pc;
uint hash(uint x) {
    x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15;
    x *= 0x846ca68bu; x ^= x >> 16; return x;
}
void main() {
    if (pick.target.w == 0) { return; }
    ivec3 delta = ivec3(gl_GlobalInvocationID) - ivec3(pc.brush.y);
    if (dot(delta, delta) > pc.brush.y * pc.brush.y) { return; }
    ivec3 p = pick.target.xyz + delta;
    if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(pc.brush.x)))) { return; }
    uint old = uint(imageLoad(grid, p).r * 255.0 + 0.5);
    if (pc.brush.w == 1 && old != 0u) { return; }
    uint id = pc.brush.w == 2 ? 0u : uint(pc.brush.z);
    uint amount = pc.brush.w == 2 ? 0u : uint(pc.material.y);
    uint seed = hash(uint(p.x) * 73856093u ^ uint(p.y) * 19349663u ^ uint(p.z) * 83492791u ^ uint(pc.material.x)) & 255u;
    imageStore(grid, p, vec4(uvec4(id, seed, amount, 0u)) / 255.0);
    if (pc.brush.w == 2) {
        imageStore(thermal, p, vec4(imageLoad(thermal, p).r, 0.0, 0.0, 0.0));
    } else {
        imageStore(thermal, p, vec4(ELEM_INITIAL_TEMP(elems[id]), 0.0, 0.0, 0.0));
    }
}
