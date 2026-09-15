#[compute]
#version 450
#include "../momentum_gpu/common.glslinc"
#include "mechanics.glslinc"
layout(local_size_x=64,local_size_y=1,local_size_z=1) in;
void main() {
    uint i=gl_GlobalInvocationID.x;
    if(i>=pc.shape_count.w || status.value[1]!=0u) { return; }
    if(invalid.value[i]==0u && mechanics.plane.y!=0.0 && candidate.value[i].position_mass.y<mechanics.plane.x) { invalid.value[i]=4u; }
}
