#[compute]
#version 450
#include "../momentum_gpu/common.glslinc"
#include "mechanics.glslinc"
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
void main() {
    for(uint i=0u;i<pc.shape_count.w;i++) {
        Particle p=current.value[i];
        uint reason=0u;
        if(!finite_particle(p)) { reason=2u; }
        else if(!supported(p.position_mass.xyz)) { reason=1u; }
        else if(mechanics.plane.y!=0.0 && p.position_mass.y<mechanics.plane.x) { reason=4u; }
        else if(pc.time.z==0.0 && (any(notEqual(p.c0.xyz,vec3(0.0))) || any(notEqual(p.c1.xyz,vec3(0.0))) || any(notEqual(p.c2.xyz,vec3(0.0))))) { reason=3u; }
        if(reason!=0u) { status.value[5]=1u;status.value[1]=1u;status.value[2]=1u;status.value[3]=reason;status.value[4]=i;return; }
    }
}
