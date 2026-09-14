#[compute]
#version 450
#include "common.glslinc"
layout(local_size_x=64,local_size_y=1,local_size_z=1) in;
void main() {
    uint i=gl_GlobalInvocationID.x;
    if(i>=pc.shape_count.w || status.value[1]!=0u) { return; }
    Particle p=current.value[i];
    ivec3 base=base_of(p.position_mass.xyz);
    precise vec3 velocity=vec3(0.0), c0=vec3(0.0), c1=vec3(0.0), c2=vec3(0.0);
    precise float factor=4.0/(pc.time.x*pc.time.x);
    uint reason=0u;
    for(int x=0;x<3;x++) for(int y=0;y<3;y++) for(int z=0;z<3;z++) {
        ivec3 node=base+ivec3(x,y,z);
        precise float w=weight_at(p.position_mass.xyz,node);
        if(w<=0.0) { continue; }
        vec4 g=grid.value[index_of(node)];
        if(g.w<=0.0 || !finite_vec(g.xyz)) { reason=2u;continue; }
        velocity+=w*g.xyz;
        if(pc.time.z!=0.0) {
            precise vec3 offset=vec3(node)*pc.time.x-p.position_mass.xyz;
            c0+=(factor*w*g.x)*offset;c1+=(factor*w*g.y)*offset;c2+=(factor*w*g.z)*offset;
        }
    }
    p.velocity=vec4(velocity,0.0);p.c0=vec4(c0,0.0);p.c1=vec4(c1,0.0);p.c2=vec4(c2,0.0);
    precise vec3 position=p.position_mass.xyz+pc.time.y*velocity;
    p.position_mass.xyz=position;
    if(!finite_particle(p)) { reason=2u; }
    else if(!supported(position)) { reason=1u; }
    candidate.value[i]=p;invalid.value[i]=reason;
}
