#[compute]
#version 450
#include "../momentum_gpu/common.glslinc"
#include "mechanics.glslinc"
layout(local_size_x=64,local_size_y=1,local_size_z=1) in;
void main() {
    uint i=gl_GlobalInvocationID.x;
    if(i>=pc.shape_count.x*pc.shape_count.y*pc.shape_count.z || status.value[1]!=0u) { return; }
    vec4 node=grid.value[i];
    for(uint k=0u;k<7u;k++) { audit.node[i*7u+k]=vec4(0.0); }
    if(node.w<=0.0) { return; }
    precise float m=node.w;
    precise vec3 before=node.xyz, dv=mechanics.gravity.xyz*pc.time.y;
    precise vec3 after_g=before;
    if(any(notEqual(mechanics.gravity.xyz,vec3(0.0)))) { after_g+=dv; }
    precise vec3 after_w=after_g;
    float y=float((i/pc.shape_count.x)%pc.shape_count.y)*pc.time.x;
    bool selected=mechanics.plane.y!=0.0 && y<=mechanics.plane.x && after_g.y<0.0;
    if(selected) { after_w.y=0.0; }
    precise vec3 jg=m*(after_g-before),jw=m*(after_w-after_g);
    precise vec3 jg_req=m*mechanics.gravity.xyz*pc.time.y;
    precise vec3 jw_req=selected ? vec3(0.0,-m*after_g.y,0.0) : vec3(0.0);
    precise float wg=0.5*m*(dot(after_g,after_g)-dot(before,before));
    precise float ww=0.5*m*(dot(after_w,after_w)-dot(after_g,after_g));
    precise float wg_req=dot(before,jg_req)+0.5*m*dot(dv,dv);
    precise float ww_req=selected ? -0.5*m*after_g.y*after_g.y : 0.0;
    audit.node[i*7u]=node;audit.node[i*7u+1u]=vec4(after_g,0.0);audit.node[i*7u+2u]=vec4(after_w,0.0);
    audit.node[i*7u+3u]=vec4(jg,wg);audit.node[i*7u+4u]=vec4(jg_req,wg_req);
    audit.node[i*7u+5u]=vec4(jw,ww);audit.node[i*7u+6u]=vec4(jw_req,ww_req);
    grid.value[i]=vec4(after_w,m);
}
