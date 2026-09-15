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
// Authoritative thermal layer: R temperature (K), G latent progress in
// joules. Carried with material through every swap so heat belongs to the
// cell's contents, never to the grid location. Conduction, phase change and
// ignition read it (docs/milestone/thermal-physics.md).
layout(rg32f, set = 0, binding = 4) uniform restrict image3D thermal;

#include "elem.glslinc"
#include "thermal_common.glslinc"
layout(std430, set = 0, binding = 1) restrict readonly buffer Elems { Elem elems[]; };

// x = a | b << 8 | out_a << 16 | out_b << 24, y = probability * 65535 | cost << 16,
// z = minimum temperature to react (float bits, 0 = none), w = heat released
// into each non-fire output in kelvin (float bits).
layout(std430, set = 0, binding = 2) restrict readonly buffer Reacts { uvec4 reacts[]; };

// Coarse air velocity field (xyz in voxels per tick, w = heat), linear sampled.
layout(set = 0, binding = 3) uniform sampler3D air_vel;

layout(push_constant, std430) uniform Params {
	uvec4 a; // tick, seed, reserved (zero), rule flags
	uvec4 b; // partition offset x, y, z, reaction count
	uvec4 c; // thermal seconds per tick, ambient K, ignition chance per tick (float bits), unused
} pc;

const uint RULE_NO_REACTIONS = 1u;
const uint RULE_NO_DECAY = 2u;
const uint RULE_NO_AIR = 4u;
const uint RULE_NO_SPECIALS = 8u; // clone, void and the gunpowder fuse
const uint RULE_NO_THERMAL = 16u;   // no conduction, phase change or ignition (plumbing tests)
const float DX = 0.01;              // metres per voxel (VoxelSim.METRES_PER_VOXEL)
// Liquid heat capacity is exactly linear in amount (at least one unit): the
// transfer contract moves energy proportionally to units, so any floor would
// make a small receiver read colder than its donors. Keep in sync with
// hydro.glsl and VoxelSim.energy_total.
const uint CAP_FLOOR = 1u;

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
const uint FUSE_SHIFT = 4u;    // byte w bits 4..6 on Gunpowder: fuse timer, fire when it runs out
const uint FUSE_MASK = 7u << FUSE_SHIFT;
const uint FUSE_TICKS = 7u;    // lit grains keep lighting block partners this many ticks
const uint FIRE = 5u;
const uint GUNPOWDER = 16u;
const uint CLONE = 19u;
const uint VOID = 20u;
const float CLONE_RATE = 0.02; // per air partner per tick

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

float cell_capacity(uint id, uint amount) {
	float cap = ELEM_HEAT_CAPACITY(elems[id]);
	if (is_liquid(id)) {
		cap *= float(max(amount, CAP_FLOOR)) / float(FULL);
	}
	return cap;
}
float capacity_of(int i) { return cell_capacity(c[i].x, c[i].z); }
// Fraction of a cell that counts toward a phase transition's latent energy.
float fill_of(int i) { return is_liquid(c[i].x) ? float(max(c[i].z, CAP_FLOOR)) / float(FULL) : 1.0; }

// Turn cell i into element id with that element's default amount, keeping its
// seed and temperature (a transmutation is not a heat source); stored latent
// progress belongs to the old phase and is dropped. Fire is pinned to its
// flame temperature.
// Byte w bits 3..7 are element-specific (clone armed, fuse timer) and must
// not survive a transmutation; bits 0..2 are movement flags.
void set_element(int i, uint id) {
	c[i].x = id;
	c[i].z = is_liquid(id) ? FULL : 0u;
	c[i].w &= 7u;
	ct[i].y = 0.0;
	float flame = ELEM_FIRE_TEMP(elems[id]);
	if (flame > 0.0) { ct[i].x = flame; }
}

// Material created from nothing (clone emission) starts at its own initial
// temperature rather than inheriting the air's.
void set_element_fresh(int i, uint id) {
	set_element(i, id);
	ct[i] = vec2(ELEM_INITIAL_TEMP(elems[id]), 0.0);
}

// Heat carried by `m` amount units of liquid L moving from cell `from` to
// cell `to` (amounts are written by the caller). A whole parcel entering an
// empty cell exchanges thermal state with the air it displaces; otherwise
// the receiver mixes by capacity-weighted mean and the donor is unchanged.
void move_heat(int from, int to, uint L, uint m, uint from_old, uint to_old, uint from_new) {
	if (m == 0u) {
		return;
	}
	if (to_old == 0u && from_new == 0u) {
		vec2 t = ct[from]; ct[from] = ct[to]; ct[to] = t;
		return;
	}
	float Cm = ELEM_HEAT_CAPACITY(elems[L]) * float(m) / float(FULL);
	float Cr = cell_capacity(to_old == 0u ? AIR : L, to_old);
	ct[to].x = (Cr * ct[to].x + Cm * ct[from].x) / (Cr + Cm);
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
	c[i].w &= 7u;
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
				float min_t = uintBitsToFloat(re.z);
				if (min_t > 0.0 && max(ct[i].x, ct[j].x) < min_t) {
					break; // too cold for this rule; one rule per pair
				}
				uint new_a = fwd ? out_a : out_b;
				uint new_b = fwd ? out_b : out_a;
				// An input that survives as itself keeps its amount, minus the
				// rule's cost when it is a liquid (acid thins as it eats).
				if (new_a == a) { if (is_liquid(a)) { set_liquid(i, a, c[i].z > cost ? c[i].z - cost : 0u); } }
				else { set_element(i, new_a); }
				if (new_b == b) { if (is_liquid(b)) { set_liquid(j, b, c[j].z > cost ? c[j].z - cost : 0u); } }
				else { set_element(j, new_b); }
				// Heat of reaction goes into the outputs that are not already flames.
				float heat = uintBitsToFloat(re.w);
				if (heat != 0.0) {
					if (ELEM_FIRE_TEMP(elems[c[i].x]) <= 0.0) { ct[i].x += heat; }
					if (ELEM_FIRE_TEMP(elems[c[j].x]) <= 0.0) { ct[j].x += heat; }
				}
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

// Clone, Void and lit Gunpowder. Every read and write stays inside the
// thread's 2x2x2 block, as for every other rule: reading a face neighbour in
// another block would race that block's writes this tick. Detection uses
// before[] (the block as loaded), so the result does not depend on the order
// cells are visited. The rotating partition offset shares each face pair on
// about half the ticks, so a fuse advances about one cell every two ticks and
// a clone arms within a few ticks of something resting against it.
//
// Clone arms itself with the first solid, powder or liquid on a partner face
// (never a gas), or from an armed clone partner so a clone body shares one
// material; the id is kept in byte y and flagged in byte w so a paint seed
// is never mistaken for an id. Armed clones emit into air partners at
// CLONE_RATE. Void swallows any partner that is not air, wall or another
// special. Gunpowder touching fire in its block starts a FUSE_TICKS timer;
// while the timer runs the grain lights unlit gunpowder partners in its block
// each tick, and when it runs out the grain becomes fire. Seven ticks give
// each face neighbour a 1 - 2^-7 chance of having shared a block, so a fuse
// runs reliably along a trail at about a cell every two ticks.
bool is_special(uint id) { return id == CLONE || id == VOID; }

void rule_special() {
	for (int i = 0; i < 8; i++) {
		uint me = c[i].x;
		if (me == CLONE) {
			bool armed = (c[i].w & CLONE_ARMED) != 0u;
			for (int axis = 0; axis < 3 && !armed; axis++) {
				uvec4 n = before[i ^ (1 << axis)];
				uint copy = 0u;
				if (n.x == CLONE) {
					if ((n.w & CLONE_ARMED) != 0u) { copy = n.y; }
				} else if (n.x != WALL && !is_special(n.x) && !is_gas(n.x)) {
					copy = n.x;
				}
				if (copy != 0u) {
					c[i].y = copy;
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
					set_element_fresh(j, copy);
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
			uint timer = (before[i].w & FUSE_MASK) >> FUSE_SHIFT;
			if (timer == 0u) {
				for (int axis = 0; axis < 3; axis++) {
					if (before[i ^ (1 << axis)].x == FIRE) {
						timer = FUSE_TICKS + 1u;
						break;
					}
				}
				if (timer == 0u) {
					continue;
				}
			}
			for (int axis = 0; axis < 3; axis++) {
				int j = i ^ (1 << axis);
				if (c[j].x == GUNPOWDER && (c[j].w & FUSE_MASK) == 0u) {
					c[j].w |= FUSE_TICKS << FUSE_SHIFT;
				}
			}
			timer -= 1u;
			if (timer == 0u) {
				c[i] = uvec4(FIRE, c[i].y, 0u, 0u);
			} else {
				c[i].w = (c[i].w & ~FUSE_MASK) | (timer << FUSE_SHIFT);
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
	uint zb = c[b].z, zt = c[t].z;
	uint S = zt + zb;
	uint nb = min(stable_bottom(S), MAX_AMOUNT);
	uint nt = S - nb;
	if (nb > zb) {
		move_heat(t, b, L, nb - zb, zt, zb, nt);
	} else if (nb < zb) {
		move_heat(b, t, L, zb - nb, zb, zt, nb);
	}
	set_liquid(b, L, nb);
	set_liquid(t, L, nt);
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
	// Heat follows the amounts with the "retain local material" closure: each
	// cell keeps min(old, new) units at its own energy per unit, and surplus
	// donors feed deficit cells in block order. Full mixing was tried first and
	// smeared latent progress across a pool so nothing could ever boil.
	uint old_a[4];
	uint new_a[4];
	uint surplus[4];
	float e_unit[4];
	float e_new[4];
	float e_surplus[4];
	bool elig[4];
	int k_out = 0;
	for (int k = 0; k < 4; k++) {
		int i = cells[k];
		uint id = c[i].x;
		elig[k] = (id == L) || (into_air && id == AIR);
		old_a[k] = (elig[k] && id == L) ? c[i].z : 0u;
		float E = (elig[k] && id == L) ? capacity_of(i) * ct[i].x + ct[i].y : 0.0;
		e_unit[k] = (old_a[k] > 0u) ? E / float(old_a[k]) : 0.0;
		new_a[k] = 0u;
		e_new[k] = 0.0;
		surplus[k] = 0u;
		e_surplus[k] = 0.0;
		if (!elig[k]) {
			continue;
		}
		uint amount = share + ((uint(k_out) < rem) ? 1u : 0u);
		k_out++;
		new_a[k] = amount;
		uint kept = min(old_a[k], amount);
		e_new[k] = e_unit[k] * float(kept);
		if (old_a[k] > amount) {
			surplus[k] = old_a[k] - amount;
			e_surplus[k] = E - e_new[k];
		}
	}
	int d = 0;
	for (int r = 0; r < 4; r++) {
		if (!elig[r] || new_a[r] <= old_a[r]) {
			continue;
		}
		uint need = new_a[r] - old_a[r];
		while (need > 0u) {
			while (d < 4 && surplus[d] == 0u) { d++; }
			if (d >= 4) { break; }
			uint units = min(surplus[d], need);
			float q = (units == surplus[d]) ? e_surplus[d] : e_unit[d] * float(units);
			e_new[r] += q;
			e_surplus[d] -= q;
			surplus[d] -= units;
			need -= units;
		}
	}
	for (int k = 0; k < 4; k++) {
		if (!elig[k]) {
			continue;
		}
		int i = cells[k];
		set_liquid(i, L, new_a[k]);
		if (new_a[k] == 0u) {
			ct[i].y = 0.0; // the air left behind keeps the temperature
		} else {
			float C = capacity_of(i);
			ct[i] = settle(vec2(e_new[k] / C, 0.0), C, ELEM_HOT_AT(elems[L]), ELEM_COLD_AT(elems[L]));
		}
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
			float E = capacity_of(best) * ct[best].x + ct[best].y + capacity_of(i) * ct[i].x + ct[i].y;
			ct[i].y = 0.0;
			set_liquid(best, L, c[best].z + c[i].z);
			set_liquid(i, L, 0u);
			float C = capacity_of(best);
			ct[best] = settle(vec2(E / C, 0.0), C, ELEM_HOT_AT(elems[L]), ELEM_COLD_AT(elems[L]));
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

// --- heat --------------------------------------------------------------------

// Flames are heat sources: they hold their flame temperature no matter what
// they touch, for as long as they live.
void pin_fire() {
	for (int i = 0; i < 8; i++) {
		float flame = ELEM_FIRE_TEMP(elems[c[i].x]);
		if (flame > 0.0) { ct[i].x = flame; }
	}
}

// Conduction across the block's twelve faces. Each face moves the canonical
// transfer (thermal_common.glslinc), clamped to half the amount that would
// equalise the pair so a large step can never overshoot; pairs are applied in
// sequence so the update is unconditionally stable. Faces to cells outside
// the box and to materials with zero conductivity carry nothing.
void rule_thermal() {
	float dt = uintBitsToFloat(pc.c.x);
	pin_fire();
	for (int i = 0; i < 8; i++) {
		if (!in_bounds(pos[i])) { continue; }
		for (int axis = 0; axis < 3; axis++) {
			int bit = 1 << axis;
			if ((i & bit) != 0) { continue; }
			int j = i | bit;
			if (!in_bounds(pos[j])) { continue; }
			float ki = ELEM_CONDUCTIVITY(elems[c[i].x]);
			float kj = ELEM_CONDUCTIVITY(elems[c[j].x]);
			if (ki <= 0.0 || kj <= 0.0) { continue; }
			bool i_low = (pos[i].x + GRID * (pos[i].y + GRID * pos[i].z)) < (pos[j].x + GRID * (pos[j].y + GRID * pos[j].z));
			int lo = i_low ? i : j;
			int hi = i_low ? j : i;
			float k_lo = i_low ? ki : kj;
			float k_hi = i_low ? kj : ki;
			float C_lo = capacity_of(lo);
			float C_hi = capacity_of(hi);
			// A flame is pinned to its temperature, so for the overshoot clamp it
			// is an unbounded reservoir, not a 0.05 J/K wisp of gas.
			if (ELEM_FIRE_TEMP(elems[c[lo].x]) > 0.0) { C_lo = 1.0e6; }
			if (ELEM_FIRE_TEMP(elems[c[hi].x]) > 0.0) { C_hi = 1.0e6; }
			float q = canonical_transfer(k_lo, k_hi, ct[lo].x, ct[hi].x, DX, dt);
			float q_eq = (ct[hi].x - ct[lo].x) * C_lo * C_hi / (C_lo + C_hi);
			q = sign(q_eq) * min(abs(q), 0.5 * abs(q_eq));
			ct[lo].x += q / C_lo; // a flame's share is negligible and repinned below
			ct[hi].x -= q / C_hi;
		}
	}
	pin_fire();
}

// Phase change through the latent plateau and ignition by temperature. A
// cell above hot_at accumulates latent progress while staying at hot_at, and
// becomes hot_to once that progress reaches the lower phase's latent energy
// (latent K x capacity, scaled by fill); cooling below cold_at mirrors this
// with the same energy, released on transition. Flammables at or above their
// ignition temperature catch with a per-tick chance.
void rule_phase() {
	float ignite = uintBitsToFloat(pc.c.z);
	for (int i = 0; i < 8; i++) {
		uint id = c[i].x;
		if (id == AIR) { continue; }
		float hot = ELEM_HOT_AT(elems[id]);
		float cold = ELEM_COLD_AT(elems[id]);
		if (hot > 0.0 || cold > 0.0) {
			float C = capacity_of(i);
			float fill = fill_of(i);
			uint hot_to = ELEM_HOT_TO(elems[id]);
			uint cold_to = ELEM_COLD_TO(elems[id]);
			// A cell already past its plateau by more than the transition's
			// latent energy (painted cold lava, water dropped into a furnace)
			// changes phase at its own temperature: pinning it to the plateau
			// first would make it a heat source of energy it never had.
			if (hot > 0.0 && hot_to != 0u && ct[i].y <= 0.0
					&& C * (ct[i].x - hot) >= ELEM_LATENT(elems[id]) * ELEM_HEAT_CAPACITY(elems[id]) * fill) {
				float keep = ct[i].x;
				set_element(i, hot_to);
				if (ELEM_FIRE_TEMP(elems[c[i].x]) <= 0.0) { ct[i] = vec2(keep, 0.0); }
				continue;
			}
			if (cold > 0.0 && cold_to != 0u && ct[i].y >= 0.0
					&& C * (cold - ct[i].x) >= ELEM_LATENT(elems[cold_to]) * ELEM_HEAT_CAPACITY(elems[cold_to]) * fill) {
				float keep = ct[i].x;
				set_element(i, cold_to);
				ct[i] = vec2(keep, 0.0);
				continue;
			}
			ct[i] = settle(ct[i], C, hot, cold);
			if (hot > 0.0 && hot_to != 0u && ct[i].y > 0.0
					&& ct[i].y >= ELEM_LATENT(elems[id]) * ELEM_HEAT_CAPACITY(elems[id]) * fill) {
				set_element(i, hot_to);
				ct[i] = vec2(hot, 0.0);
				continue;
			}
			if (cold > 0.0 && cold_to != 0u && ct[i].y < 0.0
					&& -ct[i].y >= ELEM_LATENT(elems[cold_to]) * ELEM_HEAT_CAPACITY(elems[cold_to]) * fill) {
				set_element(i, cold_to);
				ct[i] = vec2(cold, 0.0);
				continue;
			}
		}
		float ignition = ELEM_IGNITION_TEMP(elems[id]);
		if (ignition > 0.0 && (flags_of(id) & FLAG_FLAMMABLE) != 0u && ct[i].x >= ignition) {
			uint burn = ELEM_BURN_TO(elems[id]);
			if (burn != 0u && rnd() < ignite) {
				set_element(i, burn);
			}
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

	if ((pc.a.w & RULE_NO_THERMAL) == 0u) {
		rule_thermal();
		rule_phase();
	}
	if ((pc.a.w & RULE_NO_SPECIALS) == 0u) {
		rule_special();
	}
	if ((pc.a.w & RULE_NO_REACTIONS) == 0u) {
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
