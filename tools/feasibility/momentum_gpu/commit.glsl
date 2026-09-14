#[compute]
#version 450
#include "common.glslinc"
// Tiny reference: one invocation owns the entire decision, copy and status.
// This avoids reading a halt word concurrently with another invocation writing it.
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
void main() {
    if(status.value[1]!=0u) { return; }
    for(uint p=0u;p<pc.shape_count.w;p++) {
        if(invalid.value[p]!=0u) {
            status.value[1]=1u;status.value[2]++;
            status.value[3]=invalid.value[p];status.value[4]=p;
            return;
        }
    }
    for(uint p=0u;p<pc.shape_count.w;p++) { current.value[p]=candidate.value[p]; }
    status.value[0]++;
}
