#[compute]
#version 450
#include "fused_common.glslinc"
#include "reuse_common.glslinc"
layout(local_size_x=8,local_size_y=4,local_size_z=4) in;
layout(std430,set=0,binding=3) writeonly buffer Audit { vec4 value[]; } audit;
void main() {
    uvec3 p=gl_GlobalInvocationID;
    if (any(greaterThanEqual(p,pc.shape.xyz))) { return; }
    uint i=index_of(p);
    vec3 positive,negative;
    cell_faces(p,positive,negative);
    audit.value[i*2u]=vec4(positive,0.0);
    audit.value[i*2u+1u]=vec4(negative,0.0);
}
