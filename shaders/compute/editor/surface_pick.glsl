#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(rgba8, set = 0, binding = 0) uniform readonly image3D grid;
layout(std430, set = 0, binding = 1) buffer Result {
    ivec4 hit; ivec4 normal; ivec4 target; ivec4 stats;
} result;
layout(push_constant, std430) uniform Params {
    vec4 origin; vec4 direction;
    ivec4 options; // grid, radius, erase, included element bitmask
    ivec4 section; // enabled, axis, maximum visible cell, unused
} pc;
void main() {
    result.hit = ivec4(-1); result.normal = ivec4(0);
    result.target = ivec4(-1, -1, -1, 0); result.stats = ivec4(0);
    vec3 origin = (pc.origin.xyz + 0.5) * float(pc.options.x);
    vec3 dir = normalize(pc.direction.xyz);
    vec3 hi = vec3(float(pc.options.x));
    if (pc.section.x != 0) { hi[pc.section.y] = float(pc.section.z + 1); }
    float enter = -1e30, leave = 1e30;
    int entry_axis = 0;
    for (int axis = 0; axis < 3; axis++) {
        if (abs(dir[axis]) < 1e-8) {
            if (origin[axis] < 0.0 || origin[axis] >= hi[axis]) { return; }
        } else {
            float a = -origin[axis] / dir[axis];
            float b = (hi[axis] - origin[axis]) / dir[axis];
            float near_t = min(a, b);
            if (near_t > enter) { enter = near_t; entry_axis = axis; }
            leave = min(leave, max(a, b));
        }
    }
    float t = max(enter, 0.0);
    if (leave <= t) { return; }
    ivec3 cell = ivec3(floor(origin + dir * (t + 1e-4)));
    ivec3 step_dir = ivec3(sign(dir));
    ivec3 normal = ivec3(0);
    if (enter >= 0.0) { normal[entry_axis] = -step_dir[entry_axis]; }
    vec3 delta = vec3(1e30), next_t = vec3(1e30);
    for (int axis = 0; axis < 3; axis++) {
        if (abs(dir[axis]) >= 1e-8) {
            delta[axis] = abs(1.0 / dir[axis]);
            float face = float(cell[axis] + (step_dir[axis] > 0 ? 1 : 0));
            next_t[axis] = (face - origin[axis]) / dir[axis];
        }
    }
    for (int i = 0; i < pc.options.x * 3 + 3; i++) {
        if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(vec3(cell), hi))) { return; }
        uint id = uint(imageLoad(grid, cell).r * 255.0 + 0.5);
        result.stats.x = i + 1;
        if (id != 0u && (pc.options.w & (1 << int(id))) != 0) {
            result.hit = ivec4(cell, int(id));
            result.normal = ivec4(normal, 1);
            ivec3 target = pc.options.z != 0 ? cell : cell + normal * (pc.options.y + 1);
            bool valid = (pc.options.z != 0 || any(notEqual(normal, ivec3(0))))
                && all(greaterThanEqual(target, ivec3(0))) && all(lessThan(vec3(target), hi));
            result.target = ivec4(target, valid ? 1 : 0);
            return;
        }
        int axis = next_t.x <= next_t.y && next_t.x <= next_t.z ? 0 : (next_t.y <= next_t.z ? 1 : 2);
        t = next_t[axis];
        if (t >= leave) { return; }
        // Cross simultaneous faces together: side cells touched only at an
        // edge/corner have zero ray length and must not occlude a true hit.
        // Keep the first tied axis as a deterministic placement face.
        normal = ivec3(0); normal[axis] = -step_dir[axis];
        for (int crossed = 0; crossed < 3; crossed++) {
            if (next_t[crossed] <= t + 1e-6) {
                cell[crossed] += step_dir[crossed];
                next_t[crossed] += delta[crossed];
            }
        }
    }
}
