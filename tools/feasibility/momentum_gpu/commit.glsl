#[compute]
#version 450
#include "common.glslinc"
layout(local_size_x=64,local_size_y=1,local_size_z=1) in;
void main() {
    uint i=gl_GlobalInvocationID.x;
    if(i>=pc.shape_count.w || status.value[1]!=0u) { return; }
    uint reason=0u,bad=0u;
    for(uint p=0u;p<pc.shape_count.w;p++) {
        if(invalid.value[p]!=0u) { reason=invalid.value[p];bad=p;break; }
    }
    if(reason==0u) {
        current.value[i]=candidate.value[i];
        if(i==0u) { status.value[0]++; }
    } else if(i==0u) {
        status.value[1]=1u;status.value[2]++;status.value[3]=reason;status.value[4]=bad;
    }
}
