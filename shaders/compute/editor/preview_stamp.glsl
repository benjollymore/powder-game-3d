#[compute]
#version 450
// Ghost preview (docs/milestone/placement-brief.md contract 6): for one brush
// stamp, write which cells of the box [c - r, c + r] the stamp would change.
// This mirrors brush.glsl's decision exactly (radius box, shape, ONLY_AIR /
// ERASE material test) but writes a one-uint-per-cell mask instead of the
// grid, so the editor can draw the exact cell set before the click lands.
// Like the stamp itself, it does not clip by the visual section cut.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;
layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(std430, set = 0, binding = 1) restrict writeonly buffer Mask { uint cells[]; } mask;
layout(push_constant, std430) uniform Params {
    ivec4 center_radius; // cx, cy, cz, radius
    ivec4 mode_shape;    // mode (1 only into air, 2 erase, 3 any cell), shape (0 sphere, 1 cube, 2 disc), disc axis, grid size
} pc;
void main() {
    int r = pc.center_radius.w;
    int side = 2 * r + 1;
    ivec3 local = ivec3(gl_GlobalInvocationID);
    if (any(greaterThanEqual(local, ivec3(side)))) { return; }
    uint index = uint(local.x + side * (local.y + side * local.z));
    ivec3 d = local - ivec3(r);
    ivec3 p = pc.center_radius.xyz + d;
    uint hit = 0u;
    bool inside = true;
    if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(pc.mode_shape.w)))) {
        inside = false;
    } else if (pc.mode_shape.y == 1) {
        inside = true;
    } else if (pc.mode_shape.y == 2) {
        inside = d[clamp(pc.mode_shape.z, 0, 2)] == 0;
    } else {
        inside = d.x * d.x + d.y * d.y + d.z * d.z <= r * r;
    }
    if (inside) {
        uint id = uint(imageLoad(grid, p).r * 255.0 + 0.5);
        int mode = pc.mode_shape.x;
        hit = (mode == 1) ? uint(id == 0u) : ((mode == 2) ? uint(id != 0u) : 1u);
    }
    mask.cells[index] = hit;
}
