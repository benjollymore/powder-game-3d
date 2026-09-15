#[compute]
#version 450
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
layout(rgba8, set = 0, binding = 0) uniform readonly image3D grid;
// One 64-byte record per ray. stats: x = cells visited, y = hit temperature
// (float bits), z = hit amount, w = hit flags; the last three are the cell
// probe payload (bytes 52..63 of each record).
struct PickRecord { ivec4 hit; ivec4 normal; ivec4 target; ivec4 stats; };
layout(std430, set = 0, binding = 1) buffer Result { PickRecord records[]; } result;
layout(rg32f, set = 0, binding = 2) uniform readonly image3D thermal;
// Batch rays share the push-constant layout, one 64-byte record each.
struct RayRecord { vec4 origin; vec4 direction; ivec4 options; ivec4 section; };
layout(std430, set = 0, binding = 3) readonly buffer Rays { RayRecord rays[]; } batch;
// Cells written by the stroke in progress read as air: a stroke targets the
// surface as it was when it began and never climbs its own cap.
layout(r8, set = 0, binding = 4) uniform readonly image3D stroke_mask;
layout(push_constant, std430) uniform Params {
    vec4 origin; vec4 direction;
    ivec4 options; // grid, radius, erase, included element bitmask
    ivec4 section; // enabled, axis, maximum visible cell, batch count (0 = this push constant is the ray)
} pc;
void main() {
    uint index = gl_GlobalInvocationID.x;
    RayRecord ray;
    if (pc.section.w > 0) {
        if (index >= uint(pc.section.w)) { return; }
        ray = batch.rays[index];
    } else {
        index = 0u;
        ray = RayRecord(pc.origin, pc.direction, pc.options, pc.section);
    }
    result.records[index].hit = ivec4(-1); result.records[index].normal = ivec4(0);
    result.records[index].target = ivec4(-1, -1, -1, 0); result.records[index].stats = ivec4(0);
    vec3 origin = (ray.origin.xyz + 0.5) * float(ray.options.x);
    vec3 dir = normalize(ray.direction.xyz);
    vec3 hi = vec3(float(ray.options.x));
    if (ray.section.x != 0) { hi[ray.section.y] = float(ray.section.z + 1); }
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
    for (int i = 0; i < ray.options.x * 3 + 3; i++) {
        if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(vec3(cell), hi))) { return; }
        uvec4 v = uvec4(imageLoad(grid, cell) * 255.0 + 0.5);
        uint id = v.x;
        result.records[index].stats.x = i + 1;
        bool own = imageLoad(stroke_mask, cell).r > 0.5;
        if (id != 0u && !own && (ray.options.w & (1 << int(id))) != 0) {
            result.records[index].hit = ivec4(cell, int(id));
            result.records[index].stats.y = floatBitsToInt(imageLoad(thermal, cell).r);
            result.records[index].stats.z = int(v.z);
            result.records[index].stats.w = int(v.w);
            result.records[index].normal = ivec4(normal, 1);
            // Placement contract: an additive stamp is centred on the first air
            // cell outside the hit face, so the brush forms a cap resting on the
            // surface (ONLY_AIR keeps the solid); erase is centred on the hit cell.
            // The radius no longer moves the centre.
            ivec3 target = ray.options.z != 0 ? cell : cell + normal;
            bool valid = (ray.options.z != 0 || any(notEqual(normal, ivec3(0))))
                && all(greaterThanEqual(target, ivec3(0))) && all(lessThan(vec3(target), hi));
            result.records[index].target = ivec4(target, valid ? 1 : 0);
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
