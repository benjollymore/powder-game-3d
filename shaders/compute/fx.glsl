#[compute]
#version 450

// Persistent FX particle pool: embers, dust and splash droplets. One thread
// per slot, run once per frame while time advances (dt = sim seconds this
// frame, so freezing time freezes the particles). Dead slots claim spawn
// requests written by splat_emit.glsl; live ones advect with the air
// velocity field, fall or rise, die on contact with the smoothed opaque
// field, and write a camera-facing sprite instance into a MultiMesh buffer
// (zero-size when dead).

layout(local_size_x = 64) in;

struct Particle {
	vec4 pos_life;  // cell-space position, seconds left
	vec4 vel_kind;  // cells/s, kind (0 = dead)
	vec4 seed_age;  // seed, age in seconds, total life, unused
};
layout(std430, set = 0, binding = 0) restrict buffer Pool { Particle p[]; } pool;
struct Spawn {
	vec4 pos_kind;
	vec4 vel_seed;
};
layout(std430, set = 0, binding = 1) restrict readonly buffer Spawns { Spawn list[]; } spawns;
layout(std430, set = 0, binding = 2) buffer Counters { uint count[16]; } counters;
layout(std430, set = 0, binding = 3) restrict writeonly buffer Instances { float data[]; } inst;
layout(set = 0, binding = 4) uniform sampler3D air_vel;   // voxels per tick, AIR_GRID cells
layout(set = 0, binding = 5) uniform sampler3D fields;    // G = smoothed opaque density

layout(push_constant, std430) uniform Params {
	vec4 t;    // dt seconds, ticks per second, spawn capacity, unused
	uvec4 m;   // pool size, frame, unused
} pc;

layout(constant_id = 0) const int GRID = 128;

const float KIND_EMBER = 1.0;
const float KIND_DUST = 2.0;
const float KIND_SPLASH = 3.0;
const uint SPAWNS = 3u, CLAIM = 4u, ALIVE = 5u;

uint hash(uint a, uint b) {
	uint h = a * 73856093u ^ b * 2654435761u;
	h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
	return h;
}
float unit(uint h, int byte) { return float((h >> (8 * byte)) & 255u) / 255.0; }

void write_dead(uint i) {
	uint b = i * 16u;
	for (uint k = 0u; k < 16u; k++) { inst.data[b + k] = 0.0; }
}

void main() {
	uint i = gl_GlobalInvocationID.x;
	if (i >= pc.m.x) {
		return;
	}
	Particle q = pool.p[i];
	float dt = pc.t.x;
	if (q.vel_kind.w == 0.0) {
		uint claim = atomicAdd(counters.count[CLAIM], 1u);
		if (claim >= min(counters.count[SPAWNS], uint(pc.t.z))) {
			write_dead(i);
			return;
		}
		Spawn s = spawns.list[claim];
		uint h = hash(uint(s.vel_seed.w) + i, pc.m.y);
		float life = (s.pos_kind.w == KIND_EMBER) ? 0.9 + 1.4 * unit(h, 0)
			: (s.pos_kind.w == KIND_DUST) ? 0.6 + 0.8 * unit(h, 0)
			: 0.25 + 0.3 * unit(h, 0);
		q.pos_life = vec4(s.pos_kind.xyz, life);
		q.vel_kind = vec4(s.vel_seed.xyz, s.pos_kind.w);
		q.seed_age = vec4(float(h & 0xFFFFu), 0.0, life, 0.0);
	}

	float kind = q.vel_kind.w;
	vec3 pos = q.pos_life.xyz;
	vec3 vel = q.vel_kind.xyz;
	float G = float(GRID);
	// Air velocity is voxels per tick on the coarse grid; convert to cells/s.
	vec3 wind = textureLod(air_vel, pos / G, 0.0).xyz * pc.t.y;
	float coupling, gravity, drag;
	if (kind == KIND_EMBER) {
		coupling = 1.0; gravity = 18.0; drag = 2.5;
	} else if (kind == KIND_DUST) {
		coupling = 1.0; gravity = -10.0; drag = 3.0;
	} else {
		coupling = 0.3; gravity = -180.0; drag = 0.6;
	}
	uint hs = hash(uint(q.seed_age.x), uint(q.seed_age.y * 60.0));
	vec3 flutter = (vec3(unit(hs, 0), unit(hs, 1), unit(hs, 2)) - 0.5) * ((kind == KIND_EMBER) ? 40.0 : 6.0);
	vec3 target = wind * coupling + flutter;
	vel += (target - vel) * clamp(drag * dt, 0.0, 1.0);
	vel.y += gravity * dt;
	pos += vel * dt;
	float age = q.seed_age.y + dt;
	float life = q.pos_life.w - dt;

	bool dead = life <= 0.0;
	if (any(lessThan(pos, vec3(0.0))) || any(greaterThanEqual(pos, vec3(G)))) {
		dead = true;
	} else {
		float g = textureLod(fields, pos / G, 0.0).g;
		if (g > 0.5) {
			if (kind == KIND_DUST) {
				// Dust settles on the surface and fades there.
				pos -= vel * dt;
				vel = vec3(0.0);
			} else {
				dead = true;
			}
		}
	}
	if (dead) {
		pool.p[i] = Particle(vec4(0.0), vec4(0.0), vec4(0.0));
		write_dead(i);
		return;
	}
	pool.p[i] = Particle(vec4(pos, life), vec4(vel, kind), vec4(q.seed_age.x, age, q.seed_age.z, 0.0));
	atomicAdd(counters.count[ALIVE], 1u);

	float t01 = clamp(age / max(q.seed_age.z, 1e-3), 0.0, 1.0);
	float size;
	if (kind == KIND_EMBER) {
		size = 0.5 + 0.35 * unit(hs, 3);
	} else if (kind == KIND_DUST) {
		size = 1.2 + 3.0 * t01;
	} else {
		size = 0.45 + 0.2 * unit(hs, 3);
	}
	float s = size / G;
	vec3 o = pos / G - 0.5;
	uint b = i * 16u;
	inst.data[b + 0] = s;   inst.data[b + 1] = 0.0; inst.data[b + 2] = 0.0; inst.data[b + 3] = o.x;
	inst.data[b + 4] = 0.0; inst.data[b + 5] = s;   inst.data[b + 6] = 0.0; inst.data[b + 7] = o.y;
	inst.data[b + 8] = 0.0; inst.data[b + 9] = 0.0; inst.data[b + 10] = s;  inst.data[b + 11] = o.z;
	inst.data[b + 12] = kind;
	inst.data[b + 13] = t01;
	inst.data[b + 14] = q.seed_age.x / 65535.0;
	inst.data[b + 15] = length(vel) / G;
}
