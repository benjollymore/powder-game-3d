#[compute]
#version 450

// One simulation tick of the voxel world as a Margolus block cellular automaton.
//
// The grid is partitioned into 2x2x2 blocks; one thread owns one block and only
// ever reads/writes its own 8 cells, so there are no write hazards and every rule
// is a swap, an in-place transmute, or a transfer of liquid amount between two
// cells of the block (mass is conserved by construction). The partition offset
// changes every tick (push constant) so cells get different neighbours each tick.
//
// Voxel bytes: x = element id, y = per-voxel seed, z = liquid amount (0 for
// anything that is not a liquid), w bit 0 = liquid is in an unsupported
// (falling) run (maintained by hydro.glsl), w bits 1-2 = powder "moved age":
// 3 right after a grain moved, counting down while it rests (drives the
// airborne-grain splats).

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;
// Authoritative thermal layer: R temperature (K), G latent progress. Carried
// with material through every swap so heat belongs to the cell's contents,
// never to the grid location. No rule reads it yet (conduction lands next).
layout(rg32f, set = 0, binding = 4) uniform restrict image3D thermal;

#include "elem.glslinc"
layout(std430, set = 0, binding = 1) restrict readonly buffer Elems { Elem elems[]; };

// x = a | b << 8 | out_a << 16 | out_b << 24, y = probability * 65535.
layout(std430, set = 0, binding = 2) restrict readonly buffer Reacts { uvec4 reacts[]; };

// Coarse air velocity field (xyz in voxels per tick, w = heat), linear sampled.
layout(set = 0, binding = 3) uniform sampler3D air_vel;

layout(push_constant, std430) uniform Params {
	uvec4 a; // tick, seed, reserved (zero), rule flags
	uvec4 b; // partition offset x, y, z, reaction count
} pc;

const uint RULE_NO_REACTIONS = 1u;
const uint RULE_NO_DECAY = 2u;
const uint RULE_NO_AIR = 4u;

layout(constant_id = 0) const int GRID = 128;
const uint AIR = 0u;
const uint WALL = 1u;

const uint FLAG_IMMOVABLE = 1u << 0;
const uint FLAG_POWDER = 1u << 1;
const uint FLAG_LIQUID = 1u << 2;
const uint FLAG_GAS = 1u << 3;
const uint FLAG_FLAMMABLE = 1u << 4;

// Liquid amounts (byte z). Keep FULL in sync with Elements.LIQUID_FULL.
const uint FULL = 200u;        // nominal full cell
const uint MAX_AMOUNT = 255u;  // byte cap
const uint COMP = 2u;          // extra units held per cell of liquid above (compressibility)
const uint MIN_SPLIT = 40u;    // don't spread into empty cells below this share (a little surface tension)
const uint MIN_KEEP = 6u;      // cells below this donate everything to a neighbour
const uint FALLING = 1u;       // byte w flag: this liquid is falling (do not spray sideways)
const uint AGE_SHIFT = 1u;     // byte w bits 1-2: powder moved age
const uint CLONE_ARMED = 128u; // byte w bit 7 on a Clone cell: byte y holds the element it copies
const uint FUSE_LIT = 64u;     // byte w bit 6 on Gunpowder: lit, becomes fire next tick
const uint FIRE = 5u;
const uint GUNPOWDER = 16u;
const uint CLONE = 19u;
const uint VOID = 20u;
const float CLONE_RATE = 0.02; // per air partner per tick
const ivec3 FACES[6] = ivec3[6](ivec3(1, 0, 0), ivec3(-1, 0, 0), ivec3(0, 1, 0), ivec3(0, -1, 0), ivec3(0, 0, 1), ivec3(0, 0, -1));

// Per-invocation block state.
ivec3 origin;
ivec3 pos[8];
uvec4 c[8];
uvec4 before[8];
vec2 ct[8];
vec2 before_t[8];
uint state;

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

vec2 load_thermal(ivec3 p) {
	if (!in_bounds(p)) {
		return vec2(0.0);
	}
	return imageLoad(thermal, p).rg;
}

void store_thermal(ivec3 p, vec2 t) {
	if (in_bounds(p)) {
		imageStore(thermal, p, vec4(t, 0.0, 0.0));
	}
}

uint flags_of(uint id) { return elems[id].flags & 0xFFu; }
float density_of(uint id) { return elems[id].density; }
float spread_of(uint id) { return elems[id].spread; }
float decay_of(uint id) { return elems[id].decay; }
float coupling_of(uint id) { return elems[id].air_coupling; }
uint decay_target(uint id) { return (elems[id].flags >> 24) & 0xFFu; }
bool immovable(uint id) { return (flags_of(id) & FLAG_IMMOVABLE) != 0u; }
bool is_powder(uint id) { return (flags_of(id) & FLAG_POWDER) != 0u; }
bool is_liquid(uint id) { return (flags_of(id) & FLAG_LIQUID) != 0u; }
bool is_gas(uint id) { return (flags_of(id) & FLAG_GAS) != 0u; }

// Random float in [0,1) from the block's hash state, advancing it.
float rnd() {
	state = hash(state);
	return float(state & 0xFFFFFFu) / 16777216.0;
}

void swap_cells(int i, int j) {
	uvec4 tmp = c[i]; c[i] = c[j]; c[j] = tmp;
	vec2 tt = ct[i]; ct[i] = ct[j]; ct[j] = tt;
}

// Turn cell i into element id with that element's default amount, keeping its seed.
void set_element(int i, uint id) {
	c[i].x = id;
	c[i].z = is_liquid(id) ? FULL : 0u;
}

// Set cell i to hold `amount` of liquid L (0 makes it air), keeping its seed.
void set_liquid(int i, uint L, uint amount) {
	if (amount == 0u) {
		c[i].x = AIR;
		c[i].z = 0u;
	} else {
		c[i].x = L;
		c[i].z = amount;
	}
}

// Share of a two-cell column's total S that the bottom cell holds at rest.
// Rounded stochastically: plain truncation lets a column lock into a parity
// where it carries only half the intended compression, and columns that get
// shuffled sideways (a tank) drift to a different parity than ones that do
// not (a 1-wide pipe), so they never agree on pressure.
uint stable_bottom(uint S) {
	if (S <= FULL) {
		return S;
	}
	float bf;
	if (S <= 2u * FULL + COMP) {
		bf = float(FULL * FULL + S * COMP) / float(FULL + COMP);
	} else {
		bf = float(S + COMP) * 0.5;
	}
	return min(uint(bf + rnd()), S);
}

// Canonical block layout: index i -> local (x, y, z) = (i & 1, (i >> 1) & 1, (i >> 2) & 1).
// Column col (0..3) has bottom cell b = (col & 1) | ((col >> 1) << 2) and top cell b | 2.
int bottom_of(int col) { return (col & 1) | ((col >> 1) << 2); }

// --- rules -----------------------------------------------------------------

void rule_reactions() {
	uint n_reacts = pc.b.w;
	for (int i = 0; i < 8; i++) {
		for (int axis = 0; axis < 3; axis++) {
			int bit = 1 << axis;
			if ((i & bit) != 0) {
				continue; // each pair counted once, from its lower index
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
				// Thin films of liquid react proportionally less often.
				float p = float(re.y & 0xFFFFu) / 65535.0;
				uint cost = (re.y >> 16u) & 0xFFu;
				if (is_liquid(a)) { p *= min(1.0, float(c[i].z) / float(FULL)); }
				if (is_liquid(b)) { p *= min(1.0, float(c[j].z) / float(FULL)); }
				if (rnd() > p) {
					break;
				}
				uint new_a = fwd ? out_a : out_b;
				uint new_b = fwd ? out_b : out_a;
				// An input that survives as itself keeps its amount, minus the
				// rule's cost when it is a liquid (acid thins as it eats).
				if (new_a == a) { if (is_liquid(a)) { set_liquid(i, a, c[i].z > cost ? c[i].z - cost : 0u); } }
				else { set_element(i, new_a); }
				if (new_b == b) { if (is_liquid(b)) { set_liquid(j, b, c[j].z > cost ? c[j].z - cost : 0u); } }
				else { set_element(j, new_b); }
				break;
			}
		}
	}
}

void rule_decay() {
	for (int i = 0; i < 8; i++) {
		float p = decay_of(c[i].x);
		if (p > 0.0 && rnd() < p) {
			set_element(i, decay_target(c[i].x));
		}
	}
}

// Clone, Void and lit Gunpowder. Writes stay inside the block; detection reads
// the six face neighbours through load() so a cell is not blind to what
// touches it across this tick's partition boundary (the partition offset is
// global per tick, so a falling sheet can otherwise leave before a clone
// beside it ever shares a block with it).
//
// Clone arms itself with the first ordinary material on any face (id kept in
// byte y, flagged in byte w so a paint seed is never mistaken for an id),
// then emits that material into air partners at CLONE_RATE. Void swallows any
// partner that is not air, wall or another special. Gunpowder touching fire
// or lit gunpowder becomes lit; lit gunpowder turns into fire next tick, so a
// fuse runs one cell per tick along the trail whether or not the flame
// itself lingers.
bool is_special(uint id) { return id == CLONE || id == VOID; }

void rule_special() {
	for (int i = 0; i < 8; i++) {
		uint me = c[i].x;
		if (me == CLONE) {
			bool armed = (c[i].w & CLONE_ARMED) != 0u;
			for (int f = 0; f < 6 && !armed; f++) {
				uint other = load(pos[i] + FACES[f]).x;
				if (other != AIR && other != WALL && !is_special(other)) {
					c[i].y = other;
					c[i].w |= CLONE_ARMED;
					armed = true;
				}
			}
			if (!armed) {
				continue;
			}
			uint copy = c[i].y;
			for (int axis = 0; axis < 3; axis++) {
				int j = i ^ (1 << axis);
				if (c[j].x == AIR && rnd() < CLONE_RATE) {
					set_element(j, copy);
				}
			}
		} else if (me == VOID) {
			for (int axis = 0; axis < 3; axis++) {
				int j = i ^ (1 << axis);
				uint other = c[j].x;
				if (other != AIR && other != WALL && !is_special(other)) {
					c[j] = uvec4(AIR, c[j].y, 0u, 0u);
				}
			}
		} else if (me == GUNPOWDER) {
			if ((before[i].w & FUSE_LIT) != 0u) {
				c[i] = uvec4(FIRE, c[i].y, 0u, 0u);
				continue;
			}
			for (int f = 0; f < 6; f++) {
				uvec4 n = load(pos[i] + FACES[f]);
				if (n.x == FIRE || (n.x == GUNPOWDER && (n.w & FUSE_LIT) != 0u)) {
					c[i].w |= FUSE_LIT;
					break;
				}
			}
		}
	}
}

// Liquid amount flow between the two cells of a column, if both are air or the
// same liquid. Returns false when the pair is not such a case.
bool liquid_column(int b, int t) {
	uint top = c[t].x, bot = c[b].x;
	bool tl = is_liquid(top), bl = is_liquid(bot);
	if (!(tl || bl)) {
		return false;
	}
	if (!(top == bot || top == AIR || bot == AIR)) {
		return false;
	}
	uint L = tl ? top : bot;
	uint S = c[t].z + c[b].z;
	uint nb = min(stable_bottom(S), MAX_AMOUNT);
	set_liquid(b, L, nb);
	set_liquid(t, L, S - nb);
	return true;
}

// Heavier above lighter swaps down (covers falling and rising); same-liquid
// and liquid/air columns exchange amount instead.
void rule_vertical() {
	for (int col = 0; col < 4; col++) {
		int b = bottom_of(col);
		int t = b | 2;
		if (liquid_column(b, t)) {
			continue;
		}
		uint top = c[t].x, bot = c[b].x;
		if (top == bot || immovable(top) || immovable(bot)) {
			continue;
		}
		if (density_of(top) > density_of(bot)) {
			swap_cells(t, b);
		}
	}
}

// Liquid columns only (used again after horizontal spreading so water that
// flowed over an edge falls the same tick).
void rule_vertical_liquids() {
	for (int col = 0; col < 4; col++) {
		int b = bottom_of(col);
		liquid_column(b, b | 2);
	}
}

// Wind: cells drift with the air velocity sampled at the block centre. A cell
// moves to its block partner along one axis, chosen in proportion to the
// velocity components, when the partner lies downwind and is air or gas
// (anything denser must also be lighter than the mover). The chance is
// doubled because a given partner is in the block only on half the ticks.
void rule_wind() {
	vec3 centre = (vec3(origin) + 1.0) / float(GRID);
	vec3 u = texture(air_vel, centre).xyz;
	vec3 a = abs(u);
	float mag = a.x + a.y + a.z;
	if (mag < 0.02) {
		return;
	}
	for (int i = 0; i < 8; i++) {
		uint id = c[i].x;
		if (id == AIR || c[i].x != before[i].x) {
			continue;
		}
		float coupling = coupling_of(id);
		if (coupling <= 0.0) {
			continue;
		}
		float r = rnd() * mag;
		int axis = (r < a.x) ? 0 : ((r < a.x + a.y) ? 1 : 2);
		int bit = 1 << axis;
		bool positive = u[axis] > 0.0;
		bool i_is_low = (i & bit) == 0;
		if (positive != i_is_low) {
			continue; // partner is upwind
		}
		if (rnd() > min(a[axis] * coupling * 2.0, 1.0)) {
			continue;
		}
		int j = i ^ bit;
		uint other = c[j].x;
		bool ok = (other == AIR || is_gas(other)) && !immovable(other);
		if (ok && !is_gas(id)) {
			ok = density_of(other) < density_of(id);
		}
		if (ok && other != id) {
			swap_cells(i, j);
		}
	}
}

// A powder that could not fall straight down tries a diagonal neighbour in
// the block (random order), forming piles.
void rule_slump() {
	for (int col = 0; col < 4; col++) {
		int t = bottom_of(col) | 2;
		uint top = c[t].x;
		if (!is_powder(top) || c[t].x != before[t].x) {
			continue; // not powder, or this cell already changed this tick
		}
		if (rnd() > 0.5) {
			continue; // angle of repose: only slump some of the time
		}
		int first = int(rnd() * 3.0);
		for (int k = 0; k < 3; k++) {
			int other = (col + 1 + ((first + k) % 3)) & 3;
			int b2 = bottom_of(other);
			uint under = c[b2].x;
			if (!immovable(under) && density_of(top) > density_of(under)) {
				swap_cells(t, b2);
				break;
			}
		}
	}
}

// Liquids on one row of the block pool their amounts with neighbouring
// same-liquid cells (and air, on the top row where their supports are in-block
// and already settled) and split evenly. This levels surfaces and carries
// compressed liquid sideways, which is what pushes water through pipes.
void spread_row(bool top_row, bool allow_air) {
	int cells[4];
	for (int k = 0; k < 4; k++) {
		int i = (k & 1) | ((k >> 1) << 2);
		cells[k] = top_row ? (i | 2) : i;
	}
	int start = int(rnd() * 4.0);
	uint L = AIR;
	for (int k = 0; k < 4; k++) {
		uint id = c[cells[(start + k) & 3]].x;
		if (is_liquid(id)) {
			L = id;
			break;
		}
	}
	if (L == AIR || rnd() > spread_of(L)) {
		return;
	}
	uint total = 0u;
	int n_all = 0, n_liq = 0;
	bool resting = true;
	for (int k = 0; k < 4; k++) {
		uint id = c[cells[k]].x;
		if (id == L) {
			total += c[cells[k]].z; n_liq++; n_all++;
			if ((c[cells[k]].w & FALLING) != 0u) { resting = false; }
		}
		else if (id == AIR && allow_air) { n_all++; }
	}
	if (n_liq == 0) {
		return;
	}
	// Only liquid that is resting on something may spread into air; falling
	// water holds together instead of spraying.
	bool into_air = allow_air && resting && (total / uint(n_all)) >= MIN_SPLIT;
	int n = into_air ? n_all : n_liq;
	uint share = total / uint(n);
	uint rem = total % uint(n);
	int k_out = 0;
	for (int k = 0; k < 4; k++) {
		int i = cells[k];
		uint id = c[i].x;
		bool eligible = (id == L) || (into_air && id == AIR);
		if (!eligible) {
			continue;
		}
		uint amount = share + ((uint(k_out) < rem) ? 1u : 0u);
		k_out++;
		set_liquid(i, L, amount);
	}
	// Remnants: tiny amounts join the fullest neighbour rather than lingering.
	for (int k = 0; k < 4; k++) {
		int i = cells[k];
		if (c[i].x != L || c[i].z == 0u || c[i].z >= MIN_KEEP) {
			continue;
		}
		int best = -1;
		uint best_amount = 0u;
		for (int m = 0; m < 4; m++) {
			int j = cells[m];
			if (j != i && c[j].x == L && c[j].z > best_amount && c[j].z + c[i].z <= MAX_AMOUNT) {
				best = j;
				best_amount = c[j].z;
			}
		}
		if (best >= 0) {
			set_liquid(best, L, c[best].z + c[i].z);
			set_liquid(i, L, 0u);
		}
	}
}

void rule_liquid_spread() {
	spread_row(true, true);
	spread_row(false, false);
}

// Gases on the block's bottom row (cell above known and not heavier) drift
// into a random same-layer gas neighbour, which diffuses clouds.
void rule_gas_spread() {
	for (int i = 0; i < 8; i++) {
		uint me = c[i].x;
		if (me == AIR || !is_gas(me) || (i & 2) != 0 || c[i].x != before[i].x) {
			continue;
		}
		if (rnd() > spread_of(me)) {
			continue;
		}
		int pick = int(rnd() * 3.0);
		int j = i ^ ((pick == 0) ? 1 : ((pick == 1) ? 4 : 5));
		uint other = c[j].x;
		if (other != me && is_gas(other) && !immovable(other)) {
			swap_cells(i, j);
		}
	}
}

// --- kernel ----------------------------------------------------------------

void main() {
	origin = ivec3(gl_GlobalInvocationID) * 2 - ivec3(pc.b.xyz);
	if (any(greaterThanEqual(origin, ivec3(GRID)))) {
		return;
	}

	uint tick = pc.a.x;
	state = hash(uint(origin.x) * 73856093u ^ uint(origin.y) * 19349663u
			^ uint(origin.z) * 83492791u ^ (tick * 0x9E3779B9u) ^ pc.a.y);

	// Random horizontal symmetry per block so no direction is favoured.
	bool mirror_x = (state & 1u) != 0u;
	bool mirror_z = (state & 2u) != 0u;
	bool swap_xz = (state & 4u) != 0u;

	for (int i = 0; i < 8; i++) {
		ivec3 l = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
		if (swap_xz) { l.xz = l.zx; }
		if (mirror_x) { l.x = 1 - l.x; }
		if (mirror_z) { l.z = 1 - l.z; }
		pos[i] = origin + l;
		c[i] = load(pos[i]);
		before[i] = c[i];
		ct[i] = load_thermal(pos[i]);
		before_t[i] = ct[i];
	}

	if ((pc.a.w & RULE_NO_REACTIONS) == 0u) {
		rule_special();
		rule_reactions();
	}
	if ((pc.a.w & RULE_NO_DECAY) == 0u) {
		rule_decay();
	}
	rule_vertical();
	if ((pc.a.w & RULE_NO_AIR) == 0u) {
		rule_wind();
	}
	rule_slump();
	rule_liquid_spread();
	rule_vertical_liquids();
	rule_gas_spread();

	for (int i = 0; i < 8; i++) {
		// Normalise: liquids never sit at zero amount, non-liquids carry none.
		if (is_liquid(c[i].x) && c[i].z == 0u) {
			c[i].x = AIR;
		} else if (!is_liquid(c[i].x)) {
			c[i].z = 0u;
		}
		if (is_powder(c[i].x)) {
			uint age = (c[i].w >> AGE_SHIFT) & 3u;
			bool moved = (c[i].x != before[i].x) || (c[i].y != before[i].y);
			uint new_age = moved ? 3u : (age > 0u ? age - 1u : 0u);
			c[i].w = (c[i].w & ~(3u << AGE_SHIFT)) | (new_age << AGE_SHIFT);
		}
		if (c[i] != before[i]) {
			store(pos[i], c[i]);
		}
		if (ct[i] != before_t[i]) {
			store_thermal(pos[i], ct[i]);
		}
	}
}
