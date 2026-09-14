#[compute]
#version 450
#include "common.glslinc"
layout(local_size_x=64,local_size_y=1,local_size_z=1) in;
void main() {
    uint i=gl_GlobalInvocationID.x;
    if(i>=pc.shape_count.x*pc.shape_count.y*pc.shape_count.z || status.value[1]!=0u) { return; }
    ivec3 node=ivec3(i%pc.shape_count.x,(i/pc.shape_count.x)%pc.shape_count.y,i/(pc.shape_count.x*pc.shape_count.y));
    precise float mass=0.0;
    precise vec3 momentum=vec3(0.0);
    for(uint pidx=0u;pidx<pc.shape_count.w;pidx++) {
        Particle p=current.value[pidx];
        precise float w=weight_at(p.position_mass.xyz,node);
        if(w<=0.0) { continue; }
        precise float dm=w*p.position_mass.w;
        precise vec3 offset=vec3(node)*pc.time.x-p.position_mass.xyz;
        precise vec3 v=p.velocity.xyz;
        if(pc.time.z!=0.0) { v+=vec3(dot(p.c0.xyz,offset),dot(p.c1.xyz,offset),dot(p.c2.xyz,offset)); }
        mass+=dm;momentum+=dm*v;
    }
    grid.value[i]=vec4(mass>0.0 ? momentum/mass : vec3(0.0),mass);
}
