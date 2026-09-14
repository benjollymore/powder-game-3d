#[compute]
#version 450
#include "fused_common.glslinc"
layout(local_size_x=8,local_size_y=4,local_size_z=4) in;
layout(std430,set=0,binding=3) writeonly buffer States { vec2 value[]; } states;
void main() {
    uvec3 p=gl_GlobalInvocationID;
    if (any(greaterThanEqual(p,pc.shape.xyz))) { return; }
    uint i=index_of(p);
    states.value[i]=state_of(i);
}
