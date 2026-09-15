#[compute]
#version 450

// Initialise the authoritative thermal layer from the material layer: every
// cell takes its element's initial temperature (kelvin) and zero latent
// progress. Runs after any whole-world replacement that carries no thermal
// bytes of its own (scenario ops, legacy uploads, clear). Never runs per tick.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba8, set = 0, binding = 0) uniform readonly image3D grid;
layout(rg32f, set = 0, binding = 1) uniform writeonly image3D thermal;
// Per element id: initial temperature in kelvin (PALETTE_SIZE entries).
layout(std430, set = 0, binding = 2) restrict readonly buffer Initial { float initial_temp[]; };

layout(push_constant, std430) uniform Params {
	vec4 ambient; // x = ambient temperature for ids beyond the table, y = table entry count
} pc;

layout(constant_id = 0) const int GRID = 128;

void main() {
	ivec3 p = ivec3(gl_GlobalInvocationID);
	if (any(greaterThanEqual(p, ivec3(GRID)))) {
		return;
	}
	uint id = uint(imageLoad(grid, p).r * 255.0 + 0.5);
	// The entry count comes from the push constant: a runtime array's
	// length() is not available on the Metal backend and reads as zero.
	float t = id < uint(pc.ambient.y) ? initial_temp[id] : pc.ambient.x;
	imageStore(thermal, p, vec4(t, 0.0, 0.0, 0.0));
}
