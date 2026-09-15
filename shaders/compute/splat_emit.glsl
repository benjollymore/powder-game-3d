#[compute]
#version 450

// Collects per-cell sprites into MultiMesh instance buffers, once per world
// change. One thread per voxel; a workgroup covers one 8^3 brick and exits
// early when the occupancy grid says it holds nothing of interest.
//   grains   airborne powder cells (moved recently, nothing under them)
//   leaves   plant cells exposed to air, except long vertical runs (bark)
//   droplets falling liquid cells thin enough to read as spray
//   spawns   requests for the persistent FX pool (fx.glsl): embers off fire,
//            dust where grains land, splash droplets where liquid lands
//
// MultiMesh 3D instance layout (use_custom_data, no colours): 16 floats:
// rows of the 3x4 transform (xx xy xz ox / yx yy yz oy / zx zy zz oz) then
// the custom vec4 as plain floats. Instances are in the sim volume's model
// space (unit box).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba8, set = 0, binding = 0) uniform restrict readonly image3D grid;
layout(rgba8, set = 0, binding = 1) uniform restrict readonly image3D occupancy;

#include "elem.glslinc"
layout(std430, set = 0, binding = 2) restrict readonly buffer Elems { Elem elems[]; };
// 0 grains, 1 leaves, 2 droplets, 3 spawns, 4 fx claim, 5 fx alive, 6-7 unused,
// then activity for the soundscape, reduced once per workgroup:
// 8-11 falling/landing liquid cells: count, sum x, sum y, sum z (cells);
// 12-15 fire cells the same; 16-19 steam cells the same; 20 all liquid cells.
// 21-23 exact eligible grains/leaves/droplets, independent of capped allocation.
layout(std430, set = 0, binding = 3) buffer Counters { uint count[32]; } counters;
layout(std430, set = 0, binding = 4) restrict writeonly buffer Grains { float data[]; } grains;
layout(std430, set = 0, binding = 5) restrict writeonly buffer Leaves { float data[]; } leaves;
layout(std430, set = 0, binding = 6) restrict writeonly buffer Droplets { float data[]; } droplets;
struct Spawn {
	vec4 pos_kind;  // cell-space position, kind
	vec4 vel_seed;  // initial velocity (cells/s), seed
};
layout(std430, set = 0, binding = 7) restrict writeonly buffer Spawns { Spawn list[]; } spawns;

layout(push_constant, std430) uniform Params {
	uvec4 cap;   // grain, leaf, droplet, spawn capacities
	uvec4 misc;  // frame, steam element id, unused
} pc;

layout(constant_id = 0) const int GRID = 128;

const uint FLAG_IMMOVABLE = 1u << 0;
const uint FLAG_POWDER = 1u << 1;
const uint FLAG_LIQUID = 1u << 2;
const uint FLAG_GAS = 1u << 3;
const uint FLAG_FLAMMABLE = 1u << 4;
const uint FLAG_LEAFY = 1u << 5;
const uint FALLING = 1u;
const float FULL = 200.0;

const float KIND_EMBER = 1.0;
const float KIND_DUST = 2.0;
const float KIND_SPLASH = 3.0;

shared uint s_physical[3];

const uint GRAINS = 0u, LEAVES = 1u, DROPLETS = 2u, SPAWNS = 3u;

uvec4 cell(ivec3 p) {
	if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(GRID)))) {
		return uvec4(1u, 0u, 0u, 0u); // outside is wall
	}
	return uvec4(imageLoad(grid, p) * 255.0 + 0.5);
}

uint id_at(ivec3 p) { return cell(p).x; }

bool open(uint id) {
	return id == 0u || (elems[id].flags & FLAG_GAS) != 0u;
}

uint hash(uvec3 p, uint s) {
	uint h = p.x * 73856093u ^ p.y * 19349663u ^ p.z * 83492791u ^ s * 2654435761u;
	h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
	return h;
}

float unit(uint h, int byte) { return float((h >> (8 * byte)) & 255u) / 255.0; }

vec3 model_pos(vec3 cell_pos) { return cell_pos / float(GRID) - 0.5; }

void write_instance(uint layer, uint idx, vec3 right, vec3 up, vec3 fwd, vec3 origin, vec4 custom) {
	uint b = idx * 16u;
	float d[16] = float[16](
		right.x, up.x, fwd.x, origin.x,
		right.y, up.y, fwd.y, origin.y,
		right.z, up.z, fwd.z, origin.z,
		custom.x, custom.y, custom.z, custom.w);
	if (layer == GRAINS) {
		for (int i = 0; i < 16; i++) { grains.data[b + uint(i)] = d[i]; }
	} else if (layer == LEAVES) {
		for (int i = 0; i < 16; i++) { leaves.data[b + uint(i)] = d[i]; }
	} else {
		for (int i = 0; i < 16; i++) { droplets.data[b + uint(i)] = d[i]; }
	}
}

// Uniform-scale instance (camera-facing sprites read only size and origin).
void emit_sprite(uint layer, vec3 cell_pos, float size, vec4 custom) {
	if (counters.count[layer] >= pc.cap[layer]) {
		return; // full: skip the contended atomic (a plain read is enough here)
	}
	uint idx = atomicAdd(counters.count[layer], 1u);
	if (idx >= pc.cap[layer]) {
		return;
	}
	float s = size / float(GRID);
	write_instance(layer, idx, vec3(s, 0.0, 0.0), vec3(0.0, s, 0.0), vec3(0.0, 0.0, s), model_pos(cell_pos), custom);
}

void emit_spawn(vec3 cell_pos, float kind, vec3 vel, uint seed) {
	if (counters.count[SPAWNS] >= pc.cap[SPAWNS]) {
		return;
	}
	uint idx = atomicAdd(counters.count[SPAWNS], 1u);
	if (idx >= pc.cap[SPAWNS]) {
		return;
	}
	spawns.list[idx].pos_kind = vec4(cell_pos, kind);
	spawns.list[idx].vel_seed = vec4(vel, float(seed & 255u));
}

// --- powders --------------------------------------------------------------------

void powder(ivec3 p, uvec4 v, uint h) {
	uint age = (v.w >> 1) & 3u;
	if (age == 0u) {
		return;
	}
	bool airborne = open(id_at(p - ivec3(0, 1, 0)));
	vec3 jitter = (vec3(unit(h, 0), unit(h, 1), unit(h, 2)) - 0.5) * 0.7;
	if (airborne) {
		atomicAdd(s_physical[GRAINS], 1u);
		// Per-grain jitter from the seed byte hides the voxel lattice in a falling stream.
		float size = 0.8 + 0.5 * unit(h, 3);
		emit_sprite(GRAINS, vec3(p) + 0.5 + jitter, size, vec4(float(v.x), float(v.y) / 255.0, float(age), 0.0));
	} else if (age == 3u && open(id_at(p + ivec3(0, 1, 0)))) {
		// Landed on something this tick with sky above: a puff of dust, sometimes.
		uint hf = hash(uvec3(p), pc.misc.x * 7919u + v.y);
		if (unit(hf, 0) < 0.12) {
			vec3 vel = (vec3(unit(hf, 1), unit(hf, 2), unit(hf, 3)) - vec3(0.5, 0.0, 0.5)) * vec3(30.0, 12.0, 30.0);
			emit_spawn(vec3(p) + vec3(0.5, 1.2, 0.5) + jitter, KIND_DUST, vel, v.x | (v.y << 8));
		}
	}
}

// --- plants ---------------------------------------------------------------------

// Opposite exposed faces can cancel, including all six faces of an isolated
// plant voxel. Keep nonzero directions unchanged; otherwise choose a seeded
// exposed face so origin placement never normalizes a zero vector.
vec3 leaf_offset_direction(vec3 outward, uint open_faces, uint h) {
	if (dot(outward, outward) > 0.0) {
		return normalize(outward);
	}
	uint chosen = h % uint(bitCount(open_faces)); // plant() guarantees exposure
	for (uint face = 0u; face < 6u; face++) {
		if ((open_faces & (1u << face)) == 0u) { continue; }
		if (chosen == 0u) {
			vec3 direction = vec3(0.0);
			direction[int(face / 2u)] = (face & 1u) == 0u ? 1.0 : -1.0;
			return direction;
		}
		chosen--;
	}
	return vec3(0.0, 1.0, 0.0); // unreachable for a nonempty exposure mask
}

// A plant cell is bark when it sits in a vertical run of plant at least
// 2*T tall on both sides; everything else exposed to air grows leaf cards.
void plant(ivec3 p, uvec4 v, uint h) {
	vec3 outward = vec3(0.0);
	int exposed = 0;
	uint open_faces = 0u;
	const ivec3 dirs[6] = ivec3[6](ivec3(1, 0, 0), ivec3(-1, 0, 0), ivec3(0, 1, 0), ivec3(0, -1, 0), ivec3(0, 0, 1), ivec3(0, 0, -1));
	for (int i = 0; i < 6; i++) {
		if (open(id_at(p + dirs[i]))) {
			outward += vec3(dirs[i]);
			open_faces |= 1u << uint(i);
			exposed++;
		}
	}
	if (exposed == 0) {
		return;
	}
	int T = GRID / 16;
	int above = 0, below = 0;
	for (int k = 1; k <= T; k++) {
		if (id_at(p + ivec3(0, k, 0)) != v.x) { break; }
		above++;
	}
	for (int k = 1; k <= T; k++) {
		if (id_at(p - ivec3(0, k, 0)) != v.x) { break; }
		below++;
	}
	if (above >= T && below >= T) {
		return; // bark
	}
	atomicAdd(s_physical[LEAVES], 1u);
	if (counters.count[LEAVES] >= pc.cap[LEAVES]) {
		return;
	}
	uint idx = atomicAdd(counters.count[LEAVES], 1u);
	if (idx >= pc.cap[LEAVES]) {
		return;
	}
	// Leaf normal: outward from the exposed faces, tilted by the seed; the
	// card's long axis points from the cell along a random in-plane direction.
	vec3 n = normalize(outward + (vec3(unit(h, 0), unit(h, 1), unit(h, 2)) - 0.5) * 1.6);
	vec3 t = normalize(cross(n, abs(n.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 b = cross(t, n);
	float ang = unit(h, 3) * 6.2831853;
	vec3 axis = t * cos(ang) + b * sin(ang);   // leaf length direction (mesh +Y)
	vec3 side = cross(n, axis);                // leaf width direction (mesh +X)
	// Droop: tip sinks a little toward gravity.
	axis = normalize(axis + vec3(0.0, -0.35, 0.0));
	side = normalize(cross(n, axis));
	n = cross(axis, side);
	float len = (2.6 + 1.6 * unit(hash(uvec3(p), 99u), 0)) / float(GRID);
	float wid = len * (0.42 + 0.2 * unit(hash(uvec3(p), 7u), 1));
	vec3 origin = model_pos(vec3(p) + 0.5 + leaf_offset_direction(outward, open_faces, h) * 0.45);
	write_instance(LEAVES, idx, side * wid, axis * len, n * len, origin,
		vec4(float(v.x), float(v.y) / 255.0, unit(h, 3), float(exposed)));
}

// --- liquids --------------------------------------------------------------------

void liquid(ivec3 p, uvec4 v, uint h) {
	bool falling = (v.w & FALLING) != 0u;
	uint landed = (v.w >> 1) & 3u;
	if (falling) {
		int wet = 0;
		const ivec3 dirs[6] = ivec3[6](ivec3(1, 0, 0), ivec3(-1, 0, 0), ivec3(0, 1, 0), ivec3(0, -1, 0), ivec3(0, 0, 1), ivec3(0, 0, -1));
		for (int i = 0; i < 6; i++) {
			uint id = id_at(p + dirs[i]);
			if (id != 0u && (elems[id].flags & FLAG_LIQUID) != 0u) { wet++; }
		}
		if (wet <= 2) {
			atomicAdd(s_physical[DROPLETS], 1u);
			// Thin spray: drawn as droplets, left out of the liquid surface (fields.glsl agrees).
			float fill = clamp(float(v.z) / FULL, 0.05, 1.0);
			vec3 jitter = (vec3(unit(h, 0), unit(h, 1), unit(h, 2)) - 0.5) * 0.6;
			float size = (0.55 + 0.45 * pow(fill, 0.3333)) * (0.85 + 0.3 * unit(h, 3));
			emit_sprite(DROPLETS, vec3(p) + 0.5 + jitter, size, vec4(float(v.x), float(v.y) / 255.0, fill, 0.0));
		}
	} else if (landed == 3u && open(id_at(p + ivec3(0, 1, 0)))) {
		// Just came to rest with air above: throw a ring of splash droplets.
		uint hf = hash(uvec3(p), pc.misc.x * 7919u + v.y);
		if (unit(hf, 0) < 0.35) {
			for (int k = 0; k < 2; k++) {
				uint hk = hash(uvec3(p), hf + uint(k) * 31u);
				float a = unit(hk, 0) * 6.2831853;
				float sp = 18.0 + 22.0 * unit(hk, 1);
				vec3 vel = vec3(cos(a) * sp, 35.0 + 30.0 * unit(hk, 2), sin(a) * sp);
				emit_spawn(vec3(p) + vec3(0.5, 0.9, 0.5), KIND_SPLASH, vel, v.x | (hk << 8));
			}
		}
	}
}

// --- fire -----------------------------------------------------------------------

void fire(ivec3 p, uvec4 v, uint h) {
	if (!open(id_at(p + ivec3(0, 1, 0)))) {
		return;
	}
	uint hf = hash(uvec3(p), pc.misc.x * 7919u + v.y * 131u);
	if (unit(hf, 0) < 0.003) {
		vec3 vel = (vec3(unit(hf, 1), 0.0, unit(hf, 2)) - vec3(0.5, 0.0, 0.5)) * 24.0 + vec3(0.0, 40.0 + 40.0 * unit(hf, 3), 0.0);
		vec3 jitter = (vec3(unit(h, 0), unit(h, 1), unit(h, 2)) - 0.5) * 0.8;
		emit_spawn(vec3(p) + 0.5 + jitter, KIND_EMBER, vel, hf);
	}
}

const uint ACT_WATER = 8u, ACT_FIRE = 12u, ACT_STEAM = 16u, ACT_LIQUID = 20u;
shared uint s_act[13];

void tally(uint base, ivec3 p) {
	uint k = base - ACT_WATER;
	atomicAdd(s_act[k], 1u);
	atomicAdd(s_act[k + 1u], uint(p.x));
	atomicAdd(s_act[k + 2u], uint(p.y));
	atomicAdd(s_act[k + 3u], uint(p.z));
}

void main() {
	ivec3 brick = ivec3(gl_WorkGroupID);
	vec4 occ = imageLoad(occupancy, brick);
	if (occ.r < 0.5 && occ.g < 0.5) {
		return; // uniform per workgroup, so the barriers below stay balanced
	}
	if (gl_LocalInvocationIndex < 3u) {
		s_physical[gl_LocalInvocationIndex] = 0u;
	}
	if (gl_LocalInvocationIndex < 13u) {
		s_act[gl_LocalInvocationIndex] = 0u;
	}
	barrier();
	ivec3 p = ivec3(gl_GlobalInvocationID);
	uvec4 v = cell(p);
	uint id = v.x;
	if (id != 0u) {
		uint flags = elems[id].flags;
		uint h = hash(uvec3(p), v.y);
		if ((flags & FLAG_POWDER) != 0u) {
			powder(p, v, h);
		} else if ((flags & FLAG_LIQUID) != 0u) {
			liquid(p, v, h);
			atomicAdd(s_act[ACT_LIQUID - ACT_WATER], 1u);
			if ((v.w & 7u) != 0u) {
				tally(ACT_WATER, p);
			}
		} else if ((flags & FLAG_GAS) != 0u) {
			if (elems[id].heat >= 1.0) {
				fire(p, v, h);
				tally(ACT_FIRE, p);
			} else if (id == pc.misc.y) {
				tally(ACT_STEAM, p);
			}
		} else if ((flags & FLAG_LEAFY) != 0u) {
			plant(p, v, h);
		}
	}
	barrier();
	if (gl_LocalInvocationIndex < 3u && s_physical[gl_LocalInvocationIndex] != 0u) {
		atomicAdd(counters.count[21u + gl_LocalInvocationIndex], s_physical[gl_LocalInvocationIndex]);
	}
	if (gl_LocalInvocationIndex < 13u && s_act[gl_LocalInvocationIndex] != 0u) {
		atomicAdd(counters.count[ACT_WATER + gl_LocalInvocationIndex], s_act[gl_LocalInvocationIndex]);
	}
}
