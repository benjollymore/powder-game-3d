#[compute]
#version 450
// Isolated stationary-cell experiment; does not bind production voxel state.
layout(local_size_x=8, local_size_y=4, local_size_z=4) in;
struct Material { vec4 transport; vec4 phase; }; // rho,k,cp_s,cp_l; Tm,L,h_at_melt,unused
layout(std430,set=0,binding=0) readonly buffer Energy { float value[]; } energy;
layout(std430,set=0,binding=1) readonly buffer Materials { Material value[]; } materials;
layout(std430,set=0,binding=2) readonly buffer Ids { uint value[]; } ids;
layout(std430,set=0,binding=3) writeonly buffer Flux { vec4 value[]; } flux;
layout(std430,set=0,binding=4) writeonly buffer States { vec2 value[]; } states;
layout(push_constant,std430) uniform Params { uvec4 shape; vec4 time; } pc; // dx,dt
uint index_of(uvec3 p) { return p.x + pc.shape.x*(p.y + pc.shape.y*p.z); }
vec2 state_of(uint i) {
    Material m = materials.value[ids.value[i]];
    float mass = m.transport.x*pc.time.x*pc.time.x*pc.time.x;
    float relative = energy.value[i]/mass - m.phase.z;
    if (relative < 0.0) { return vec2(m.phase.x + relative/m.transport.z, 0.0); }
    if (m.phase.y > 0.0 && relative <= m.phase.y) { return vec2(m.phase.x, relative/m.phase.y); }
    return vec2(m.phase.x + (relative-m.phase.y)/m.transport.w, 1.0);
}
void main() {
    uvec3 p=gl_GlobalInvocationID;
    if (any(greaterThanEqual(p,pc.shape.xyz))) { return; }
    uint i=index_of(p);
    vec2 state=state_of(i);
    states.value[i]=state;
    float ki=materials.value[ids.value[i]].transport.y;
    vec3 transfer=vec3(0.0);
    for (uint axis=0u;axis<3u;axis++) {
        uvec3 neighbor=p; neighbor[axis]++;
        if (neighbor[axis]>=pc.shape[axis]) { continue; }
        uint j=index_of(neighbor);
        float kj=materials.value[ids.value[j]].transport.y;
        float conductance=(ki+kj==0.0) ? 0.0 : (2.0*ki*kj/(ki+kj))*pc.time.x;
        // One stored transfer per positive face; both neighbors reuse these
        // exact FP32 bits with opposite signs in the gather pass.
        transfer[axis]=pc.time.y*conductance*(state_of(j).x-state.x);
    }
    flux.value[i]=vec4(transfer,0.0);
}
