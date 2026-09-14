#[compute]
#version 450
#include "fused_common.glslinc"
layout(local_size_x=8,local_size_y=4,local_size_z=4) in;
layout(std430,set=0,binding=3) writeonly buffer NextEnergy { float value[]; } next_energy;
void main() {
    uvec3 p=gl_GlobalInvocationID;
    if (any(greaterThanEqual(p,pc.shape.xyz))) { return; }
    uint i=index_of(p);
    precise vec3 positive=vec3(0.0);
    for (uint axis=0u;axis<3u;axis++) {
        uvec3 neighbor=p; neighbor[axis]++;
        if (neighbor[axis]<pc.shape[axis]) { positive[axis]=canonical_transfer(i,index_of(neighbor)); }
    }
    // Keep the baseline gather order: +x,+y,+z, then -x,-y,-z.
    precise float delta=positive.x+positive.y+positive.z;
    for (uint axis=0u;axis<3u;axis++) {
        if (p[axis]==0u) { continue; }
        uvec3 neighbor=p; neighbor[axis]--;
        delta-=canonical_transfer(index_of(neighbor),i);
    }
    precise float value=energy.value[i]+delta;
    next_energy.value[i]=value;
}
