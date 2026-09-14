#[compute]
#version 450
#include "fused_common.glslinc"
layout(local_size_x=8,local_size_y=4,local_size_z=4) in;
// Per cell: positive x/y/z transfers, then negative x/y/z transfers. A
// positive face must have identical bits to its neighbor's negative face.
layout(std430,set=0,binding=3) writeonly buffer Audit { vec4 value[]; } audit;
void main() {
    uvec3 p=gl_GlobalInvocationID;
    if (any(greaterThanEqual(p,pc.shape.xyz))) { return; }
    uint i=index_of(p);
    vec3 positive=vec3(0.0), negative=vec3(0.0);
    for (uint axis=0u;axis<3u;axis++) {
        uvec3 neighbor=p; neighbor[axis]++;
        if (neighbor[axis]<pc.shape[axis]) { positive[axis]=canonical_transfer(i,index_of(neighbor)); }
        if (p[axis]>0u) {
            neighbor=p; neighbor[axis]--;
            negative[axis]=canonical_transfer(index_of(neighbor),i);
        }
    }
    audit.value[i*2u]=vec4(positive,0.0);
    audit.value[i*2u+1u]=vec4(negative,0.0);
}
