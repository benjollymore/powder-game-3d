#[compute]
#version 450
#include "../momentum_gpu/common.glslinc"
#include "mechanics.glslinc"
layout(local_size_x=1,local_size_y=1,local_size_z=1) in;
float energy_of(Particle p) {
    precise float d=pc.time.x*pc.time.x*0.25;
    precise float e=0.5*p.position_mass.w*(dot(p.velocity.xyz,p.velocity.xyz)+d*(dot(p.c0.xyz,p.c0.xyz)+dot(p.c1.xyz,p.c1.xyz)+dot(p.c2.xyz,p.c2.xyz)));
    return e;
}
void main() {
    if(status.value[1]!=0u) { return; }
    audit.meta.x+=1.0;audit.meta.y=0.0;
    float min_y=candidate.value[0].position_mass.y;
    for(uint p=0u;p<pc.shape_count.w;p++) { min_y=min(min_y,candidate.value[p].position_mass.y); }
    audit.meta.z=min_y;
    for(uint p=0u;p<pc.shape_count.w;p++) {
        if(invalid.value[p]!=0u) {
            status.value[1]=1u;status.value[2]++;status.value[3]=invalid.value[p];status.value[4]=p;return;
        }
    }
    precise vec4 total[10];for(int k=0;k<10;k++) { total[k]=vec4(0.0); }
    precise float kp_before=0.0,kp_after=0.0,kg_before=0.0,kg_after=0.0;
    for(uint p=0u;p<pc.shape_count.w;p++) { kp_before+=energy_of(current.value[p]);kp_after+=energy_of(candidate.value[p]); }
    uint nodes=pc.shape_count.x*pc.shape_count.y*pc.shape_count.z;
    for(uint i=0u;i<nodes;i++) {
        vec4 before=audit.node[i*7u],after=audit.node[i*7u+2u];
        if(before.w<=0.0) { continue; }
        vec3 position=vec3(i%pc.shape_count.x,(i/pc.shape_count.x)%pc.shape_count.y,i/(pc.shape_count.x*pc.shape_count.y))*pc.time.x;
        precise vec3 r=position-mechanics.origin.xyz;
        vec4 jg=audit.node[i*7u+3u],jg_req=audit.node[i*7u+4u],jw=audit.node[i*7u+5u],jw_req=audit.node[i*7u+6u];
        total[0]+=jg;total[1]+=jg_req;total[2]+=jw;total[3]+=jw_req;
        precise vec3 tg=cross(r,jg.xyz),tw=cross(r,jw.xyz);
        total[4].xyz+=tg;total[5].xyz+=tw;
        total[6].xyz+=cross(r,jg_req.xyz);total[7].xyz+=cross(r,jw_req.xyz);
        total[4].w+=length(jg.xyz)+length(jw.xyz);total[5].w+=length(tg)+length(tw);
        total[8].x+=abs(jg.w)+abs(jw.w);
        kg_before+=0.5*before.w*dot(before.xyz,before.xyz);kg_after+=0.5*before.w*dot(after.xyz,after.xyz);
    }
    total[6].w=kg_before-kp_before;total[7].w=kp_after-kg_after;
    for(int k=0;k<9;k++) { audit.total[k]+=total[k]; }
    audit.total[9]=vec4(kp_before,kg_before,kg_after,kp_after);
    for(uint p=0u;p<pc.shape_count.w;p++) { current.value[p]=candidate.value[p]; }
    status.value[0]++;audit.meta.y=1.0;
}
