#[compute]
#version 450

// One simulation tick of the voxel world as a Margolus block cellular automaton.
//
// The grid is partitioned into 2x2x2 blocks; one thread owns one block and only
// ever reads/writes its own 8 cells, so there are no write hazards and every rule
// is a swap or an in-place transmute (mass is conserved by construction). The
// partition offset changes every tick (push constant) so cells get different
// neighbours each tick.
//
// Voxel bytes: x = element id, y = per-voxel seed, z/w reserved.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;

struct Elem {
	uint flags;     // low byte: FLAG_* bits, high byte: decay target id
	float density;  // lighter rises through heavier
	float decay;    // per-tick chance to turn into decay target
	float spread;   // sideways flow chance (liquids / gases)
};
layout(std430, set = 0, binding = 1) restrict readonly buffer Elems { Elem elems[]; };

// x = a | b << 8 | out_a << 16 | out_b << 24, y = probability * 65535.
layout(std430, set = 0, binding = 2) restrict readonly buffer Reacts { uvec4 reacts[]; };

layout(push_constant, std430) uniform Params {
	uvec4 a; // tick, seed, substep, rule flags
	uvec4 b; // partition offset x, y, z, reaction count
} pc;

const uint RULE_NO_REACTIONS = 1u;
const uint RULE_NO_DECAY = 2u;

const int GRID = 128;
const uint AIR = 0u;
const uint WALL = 1u;

const uint FLAG_IMMOVABLE = 1u << 0;
const uint FLAG_POWDER = 1u << 1;
const uint FLAG_LIQUID = 1u << 2;
const uint FLAG_GAS = 1u << 3;
const uint FLAG_FLAMMABLE = 1u << 4;

// --- helpers ---------------------------------------------------------------

uint hash(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

bool in_bounds(ivec3 p) {
	return all(greaterThanEqual(p, ivec3(0))) && all(lessThan(p, ivec3(GRID)));
}

uvec4 load(ivec3 p) {
	if (!in_bounds(p)) {
		return uvec4(WALL, 0u, 0u, 0u); // outside the box is wall: free floor and walls
	}
	return uvec4(imageLoad(grid, p) * 255.0 + 0.5);
}

void store(ivec3 p, uvec4 v) {
	if (in_bounds(p)) {
		imageStore(grid, p, vec4(v) / 255.0);
	}
}

uint flags_of(uint id) { return elems[id].flags & 0xFFu; }
float density_of(uint id) { return elems[id].density; }
float spread_of(uint id) { return elems[id].spread; }
float decay_of(uint id) { return elems[id].decay; }
uint decay_target(uint id) { return (elems[id].flags >> 24) & 0xFFu; }
bool immovable(uint id) { return (flags_of(id) & FLAG_IMMOVABLE) != 0u; }
bool is_powder(uint id) { return (flags_of(id) & FLAG_POWDER) != 0u; }
bool is_liquid(uint id) { return (flags_of(id) & FLAG_LIQUID) != 0u; }
bool is_gas(uint id) { return (flags_of(id) & FLAG_GAS) != 0u; }

// May fluid `me` move sideways into a cell holding `other`?
bool can_spread_into(uint me, uint other) {
	if (other == me || immovable(other) || is_powder(other)) {
		return false;
	}
	if (is_gas(me)) {
		return is_gas(other); // gases mix freely
	}
	return density_of(other) < density_of(me); // liquids push into lighter stuff
}

// Random float in [0,1) from a hash state, advancing it.
float rnd(inout uint state) {
	state = hash(state);
	return float(state & 0xFFFFFFu) / 16777216.0;
}

// --- kernel ----------------------------------------------------------------

// Canonical block layout: index i -> local (x, y, z) = (i & 1, (i >> 1) & 1, (i >> 2) & 1).
// Column c (0..3) has bottom cell b = (c & 1) | ((c >> 1) << 2) and top cell b | 2.
int bottom_of(int column) { return (column & 1) | ((column >> 1) << 2); }

void main() {
	ivec3 origin = ivec3(gl_GlobalInvocationID) * 2 - ivec3(pc.b.xyz);
	if (any(greaterThanEqual(origin, ivec3(GRID)))) {
		return;
	}

	uint tick = pc.a.x;
	uint state = hash(uint(origin.x) * 73856093u ^ uint(origin.y) * 19349663u
			^ uint(origin.z) * 83492791u ^ (tick * 0x9E3779B9u) ^ pc.a.y);

	// Random horizontal symmetry per block so no direction is favoured.
	bool mirror_x = (state & 1u) != 0u;
	bool mirror_z = (state & 2u) != 0u;
	bool swap_xz = (state & 4u) != 0u;

	ivec3 pos[8];
	uvec4 c[8];
	for (int i = 0; i < 8; i++) {
		ivec3 l = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
		if (swap_xz) { l.xz = l.zx; }
		if (mirror_x) { l.x = 1 - l.x; }
		if (mirror_z) { l.z = 1 - l.z; }
		pos[i] = origin + l;
		c[i] = load(pos[i]);
	}
	uvec4 before[8] = c;

	// Rule: reactions between the 12 axis-adjacent pairs in the block.
	if ((pc.a.w & RULE_NO_REACTIONS) == 0u) {
		uint n_reacts = pc.b.w;
		for (int i = 0; i < 8; i++) {
			for (int axis = 0; axis < 3; axis++) {
				int bit = 1 << axis;
				if ((i & bit) != 0) {
					continue; // pair counted from its lower index
				}
				int j = i | bit;
				uint a = c[i].x, b = c[j].x;
				if (a == b) {
					continue;
				}
				for (uint r = 0u; r < n_reacts; r++) {
					uvec4 re = reacts[r];
					uint ra = re.x & 0xFFu, rb = (re.x >> 8u) & 0xFFu;
					uint out_a = (re.x >> 16u) & 0xFFu, out_b = (re.x >> 24u) & 0xFFu;
					bool fwd = (a == ra && b == rb);
					bool rev = (a == rb && b == ra);
					if (!(fwd || rev)) {
						continue;
					}
					if (rnd(state) * 65535.0 > float(re.y)) {
						break;
					}
					c[i].x = fwd ? out_a : out_b;
					c[j].x = fwd ? out_b : out_a;
					break;
				}
			}
		}
	}

	// Rule: decay. Short-lived elements turn into their decay target.
	if ((pc.a.w & RULE_NO_DECAY) == 0u) {
		for (int i = 0; i < 8; i++) {
			float p = decay_of(c[i].x);
			if (p > 0.0 && rnd(state) < p) {
				c[i].x = decay_target(c[i].x);
			}
		}
	}

	// Rule: vertical. Heavier above lighter swaps down (covers falling and rising).
	for (int col = 0; col < 4; col++) {
		int b = bottom_of(col);
		int t = b | 2;
		uint top = c[t].x, bot = c[b].x;
		if (top == bot || immovable(top) || immovable(bot)) {
			continue;
		}
		if (density_of(top) > density_of(bot)) {
			uvec4 tmp = c[t]; c[t] = c[b]; c[b] = tmp;
		}
	}

	// Rule: powder slump. A powder that could not fall straight down tries a
	// diagonal neighbour in the block (random order), forming piles.
	for (int col = 0; col < 4; col++) {
		int t = bottom_of(col) | 2;
		uint top = c[t].x;
		if (!is_powder(top) || c[t].x != before[t].x) {
			continue; // not powder, or this cell already changed this tick
		}
		if (rnd(state) > 0.5) {
			continue; // angle of repose: only slump some of the time
		}
		int first = int(rnd(state) * 3.0);
		for (int k = 0; k < 3; k++) {
			int other = (col + 1 + ((first + k) % 3)) & 3;
			int b2 = bottom_of(other);
			uint under = c[b2].x;
			if (!immovable(under) && density_of(top) > density_of(under)) {
				uvec4 tmp = c[t]; c[t] = c[b2]; c[b2] = tmp;
				break;
			}
		}
	}

	// Rule: fluid spread. Liquids and gases drift sideways within the block
	// (x, z or diagonal neighbour on the same layer), which levels puddles and
	// diffuses gas. Only cells that are blocked vertically spread, so falling
	// water does not spray: a liquid must be on the block's top row (its cell
	// below is known and, after the vertical rule, not lighter), a gas on the
	// bottom row (its cell above is known and not heavier). Cells that already
	// moved this tick are left alone.
	for (int i = 0; i < 8; i++) {
		uint me = c[i].x;
		if (me == AIR || c[i].x != before[i].x) {
			continue;
		}
		bool top_row = (i & 2) != 0;
		bool liquid = is_liquid(me);
		if (!((liquid && top_row) || (is_gas(me) && !top_row))) {
			continue;
		}
		if (rnd(state) > spread_of(me)) {
			continue;
		}
		int pick = int(rnd(state) * 3.0);
		int j = i ^ ((pick == 0) ? 1 : ((pick == 1) ? 4 : 5));
		if (can_spread_into(me, c[j].x)) {
			uvec4 tmp = c[i]; c[i] = c[j]; c[j] = tmp;
		}
	}

	for (int i = 0; i < 8; i++) {
		if (c[i] != before[i]) {
			store(pos[i], c[i]);
		}
	}
}
