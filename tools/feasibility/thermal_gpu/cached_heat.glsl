#[compute]
#version 450
#include "fused_common.glslinc"
#include "cached_common.glslinc"
layout(local_size_x=8,local_size_y=4,local_size_z=4) in;
layout(std430,set=0,binding=3) writeonly buffer NextEnergy { float value[]; } next_energy;
void main() {
    uvec3 p=gl_GlobalInvocationID;
    if (any(greaterThanEqual(p,pc.shape.xyz))) { return; }
    uint i=index_of(p);
    vec3 positive,negative;
    cell_faces(p,positive,negative);
    precise float delta=positive.x+positive.y+positive.z;
    // Skip absent negative faces exactly as the original fused gather does.
    for (uint axis=0u;axis<3u;axis++) {
        if (p[axis]>0u) { delta-=negative[axis]; }
    }
    precise float value=energy.value[i]+delta;
    next_energy.value[i]=value;
}
