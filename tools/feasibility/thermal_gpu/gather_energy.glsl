#[compute]
#version 450
layout(local_size_x=8, local_size_y=4, local_size_z=4) in;
layout(std430,set=0,binding=0) readonly buffer EnergyIn { float value[]; } old_energy;
layout(std430,set=0,binding=1) readonly buffer Flux { vec4 value[]; } flux;
layout(std430,set=0,binding=2) writeonly buffer EnergyOut { float value[]; } next_energy;
layout(push_constant,std430) uniform Params { uvec4 shape; vec4 time; } pc;
uint index_of(uvec3 p) { return p.x + pc.shape.x*(p.y + pc.shape.y*p.z); }
void main() {
    uvec3 p=gl_GlobalInvocationID;
    if (any(greaterThanEqual(p,pc.shape.xyz))) { return; }
    uint i=index_of(p);
    vec3 outgoing=flux.value[i].xyz;
    float delta=outgoing.x+outgoing.y+outgoing.z;
    for (uint axis=0u;axis<3u;axis++) {
        if (p[axis]==0u) { continue; }
        uvec3 neighbor=p; neighbor[axis]--;
        delta-=flux.value[index_of(neighbor)][axis];
    }
    next_energy.value[i]=old_energy.value[i]+delta;
}
