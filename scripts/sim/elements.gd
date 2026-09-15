class_name Elements
extends RefCounted
## Single source of truth for elements. Feeds the renderer palette, the
## compute-shader property buffer (M3+), and the palette UI (M4+).
## Adding an element = one row in TABLE (+ shader code only if it needs
## bespoke behaviour).

enum Id { AIR, WALL, SAND, WATER, STEAM, FIRE, PLANT, OIL, SMOKE, WOOD, ICE, LAVA, STONE, METAL, WAX, MOLTEN_WAX, GUNPOWDER, GAS, ACID, CLONE, VOID }

const FLAG_IMMOVABLE := 1 << 0
const FLAG_POWDER := 1 << 1
const FLAG_LIQUID := 1 << 2
const FLAG_GAS := 1 << 3
const FLAG_FLAMMABLE := 1 << 4
## Exposed cells grow leaf cards (see splat_emit.glsl).
const FLAG_LEAFY := 1 << 5

## Renderer palette slots; keep in sync with `palette[16]` in the shader.
const PALETTE_SIZE := 32

## Nominal full amount of a liquid cell (byte z). Must match FULL in sim.glsl.
const LIQUID_FULL := 200

## Index = Id. density: lighter things rise through heavier ones.
## decay: per-tick chance to turn into `decay_to`. spread: sideways flow chance.
## emission (optional): self-illumination strength; above ~1.2 it blooms.
## extinction (gases): opacity per voxel travelled when rendered as a volume.
## air_coupling: how strongly the air velocity field carries the element.
## heat: buoyancy source for the air solver.
## smooth (solids/powders): 0 keeps crisp cube faces, 1 renders as a smooth heap.
## mat: texture layer in MaterialLibrary; grain: normal noise strength; rough: roughness.
const TABLE := [
	{ "name": "Air",   "color": Color(0, 0, 0, 0),          "flags": FLAG_GAS,                     "density": 10.0,   "decay": 0.0,  "decay_to": 0, "spread": 0.0 , "category": "gases", "tip": "Empty space. Erase paints it." },
	{ "name": "Wall",  "color": Color(0.45, 0.45, 0.48),    "flags": FLAG_IMMOVABLE,               "density": 1000.0, "decay": 0.0,  "decay_to": 0, "spread": 0.0, "smooth": 0.0, "mat": 0, "grain": 0.08, "rough": 0.85 , "category": "solids", "tip": "Wall: indestructible, holds everything in." },
	{ "name": "Sand",  "color": Color(0.86, 0.72, 0.42),    "flags": FLAG_POWDER,                  "density": 200.0,  "decay": 0.0,  "decay_to": 0, "spread": 0.0, "air_coupling": 0.05, "smooth": 1.0, "mat": 1, "grain": 0.35, "rough": 0.9 , "category": "common", "tip": "Sand: pours and piles into heaps." },
	{ "name": "Water", "color": Color(0.2, 0.45, 0.9),      "flags": FLAG_LIQUID,                  "density": 100.0,  "decay": 0.0,  "decay_to": 0, "spread": 1.0, "air_coupling": 0.1 , "category": "common", "tip": "Water: flows, levels, puts out fire and boils to steam." },
	{ "name": "Steam", "color": Color(0.86, 0.89, 0.93),    "flags": FLAG_GAS,                     "density": 1.0,    "decay": 0.0005, "decay_to": 3, "spread": 0.6, "extinction": 0.12, "air_coupling": 1.0, "heat": 0.25 , "category": "gases", "tip": "Steam: rises and drifts, condenses back to water when cold." },
	{ "name": "Fire",  "color": Color(1.0, 0.45, 0.1),      "flags": FLAG_GAS,                     "density": 2.0,    "decay": 0.05, "decay_to": 8, "spread": 0.3, "emission": 2.2, "extinction": 0.2, "air_coupling": 1.0, "heat": 1.0 , "category": "heat", "tip": "Fire: burns wood, plant, oil and gas; boils water." },
	{ "name": "Plant", "color": Color(0.2, 0.7, 0.25),      "flags": FLAG_IMMOVABLE | FLAG_FLAMMABLE | FLAG_LEAFY, "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0, "smooth": 0.6, "mat": 2, "grain": 0.2, "rough": 0.7 , "category": "solids", "tip": "Plant: grows into water, burns readily." },
	{ "name": "Oil",   "color": Color(0.35, 0.25, 0.15),    "flags": FLAG_LIQUID | FLAG_FLAMMABLE, "density": 80.0,   "decay": 0.0,  "decay_to": 0, "spread": 0.5, "air_coupling": 0.1 , "category": "liquids", "tip": "Oil: floats on water and burns fiercely." },
	{ "name": "Smoke", "color": Color(0.2, 0.2, 0.22),      "flags": FLAG_GAS,                     "density": 3.0,    "decay": 0.002, "decay_to": 0, "spread": 0.5, "extinction": 0.3, "air_coupling": 1.0, "heat": 0.3 , "category": "gases", "tip": "Smoke: rises from fire and slowly clears." },
	{ "name": "Wood",  "color": Color(0.42, 0.28, 0.16),    "flags": FLAG_IMMOVABLE | FLAG_FLAMMABLE, "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0, "smooth": 0.5, "mat": 4, "grain": 0.15, "rough": 0.8 , "category": "solids", "tip": "Wood: sturdy, burns slowly." },
	# Heat milestone rows (ids 10..20, docs/milestone/heat-brief.md contract 1).
	# Tranche A (10..13): rows and colours here; the thermal worker tunes their
	# THERMAL coefficients and the hot/cold transitions that give them life.
	{ "name": "Ice",    "color": Color(0.78, 0.9, 1.0),     "flags": FLAG_IMMOVABLE,               "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0, "smooth": 0.25, "mat": 5, "grain": 0.04, "rough": 0.25, "category": "heat", "tip": "Ice: frozen water, melts when warmed." },
	{ "name": "Lava",   "color": Color(1.0, 0.35, 0.05),    "flags": FLAG_LIQUID,                  "density": 150.0,  "decay": 0.0, "decay_to": 0, "spread": 0.25, "emission": 1.8, "air_coupling": 0.02, "foam": 0.0, "opacity": 12.0, "category": "heat", "tip": "Lava: cools into stone, boils water, sets things alight." },
	{ "name": "Stone",  "color": Color(0.5, 0.48, 0.45),    "flags": FLAG_IMMOVABLE,               "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0, "smooth": 0.3, "mat": 0, "grain": 0.25, "rough": 0.9, "category": "solids", "tip": "Stone: solid rock, melts back into lava when very hot." },
	{ "name": "Metal",  "color": Color(0.62, 0.64, 0.68),   "flags": FLAG_IMMOVABLE,               "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0, "smooth": 0.0, "mat": 6, "grain": 0.02, "rough": 0.15, "category": "solids", "tip": "Metal: carries heat quickly from one end to the other." },
	# Tranche B (14..20): table-driven behaviour plus bespoke CLONE/VOID rules in sim.glsl.
	{ "name": "Wax",    "color": Color(0.93, 0.88, 0.72),   "flags": FLAG_IMMOVABLE,               "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0, "smooth": 0.4, "mat": 6, "grain": 0.03, "rough": 0.7, "category": "solids", "tip": "Wax: soft solid that melts near flame and sets again when cool." },
	{ "name": "Molten wax", "color": Color(0.95, 0.85, 0.55), "flags": FLAG_LIQUID,                "density": 90.0,   "decay": 0.0, "decay_to": 0, "spread": 0.3, "air_coupling": 0.05, "emission": 0.25, "foam": 0.3, "opacity": 5.0, "category": "liquids", "tip": "Molten wax: flows slowly and sets back into wax as it cools." },
	{ "name": "Gunpowder", "color": Color(0.22, 0.2, 0.18), "flags": FLAG_POWDER | FLAG_FLAMMABLE, "density": 210.0,  "decay": 0.0, "decay_to": 0, "spread": 0.0, "air_coupling": 0.05, "smooth": 1.0, "mat": 1, "grain": 0.5, "rough": 0.95, "category": "powders", "tip": "Gunpowder: a spark sets the whole trail off in a flash." },
	{ "name": "Gas",    "color": Color(0.75, 0.85, 0.6),    "flags": FLAG_GAS | FLAG_FLAMMABLE,    "density": 1.5,    "decay": 0.0, "decay_to": 0, "spread": 0.6, "extinction": 0.06, "air_coupling": 1.0, "category": "gases", "tip": "Gas: drifts and rises, flashes into flame on contact with fire." },
	{ "name": "Acid",   "color": Color(0.45, 0.95, 0.2),    "flags": FLAG_LIQUID,                  "density": 110.0,  "decay": 0.0, "decay_to": 0, "spread": 0.8, "emission": 0.4, "air_coupling": 0.1, "foam": 0.0, "opacity": 2.0, "category": "liquids", "tip": "Acid: eats through sand, wood, plant and more, but never wall." },
	{ "name": "Clone",  "color": Color(0.85, 0.75, 0.25),   "flags": FLAG_IMMOVABLE,               "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0, "smooth": 0.0, "mat": 7, "grain": 0.05, "rough": 0.6, "category": "special", "tip": "Clone: copies the first material that touches it, forever." },
	{ "name": "Void",   "color": Color(0.08, 0.05, 0.12),   "flags": FLAG_IMMOVABLE,               "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0, "smooth": 0.0, "mat": 3, "grain": 0.0, "rough": 1.0, "emission": 0.0, "category": "special", "tip": "Void: swallows anything that touches it, except wall." },
]


## Element categories for the palette (contract 1 of docs/milestone/heat-brief.md).
const CATEGORIES := ["common", "heat", "powders", "liquids", "gases", "solids", "special"]

## Provisional thermal coefficients per element id (heat milestone). Units:
## heat_capacity J/K per full 1 cm³ cell, conductivity W/(m·K), temperatures
## in kelvin, latent in K × capacity units (energy to cross a hot_at plateau),
## ignition_temp 0 = never ignites, hot_at/cold_at 0 = no transition.
## Values are order-of-magnitude placeholders derived from bulk properties
## (water 1 g × 4.18 J/(g·K); stone 2.6 g × 0.8; wood 0.6 g × 1.7; gases use
## a floor of 0.05 so a cell can never carry zero capacity). The thermal
## worker owns tuning them; the schema and defaults are owned here.
const THERMAL := {
	Id.AIR:   { "heat_capacity": 0.05, "conductivity": 0.026, "initial_temp": 293.15 },
	Id.WALL:  { "heat_capacity": 2.1,  "conductivity": 1.5,   "initial_temp": 293.15 },
	Id.SAND:  { "heat_capacity": 1.5,  "conductivity": 0.3,   "initial_temp": 293.15 },
	Id.WATER: { "heat_capacity": 4.18, "conductivity": 0.6,   "initial_temp": 293.15, "hot_at": 373.15, "hot_to": Id.STEAM, "latent": 540.0 },
	Id.STEAM: { "heat_capacity": 0.05, "conductivity": 0.03,  "initial_temp": 380.0,  "cold_at": 373.15, "cold_to": Id.WATER },
	Id.FIRE:  { "heat_capacity": 0.05, "conductivity": 0.1,   "initial_temp": 1200.0, "fire_temp": 1200.0 },
	Id.PLANT: { "heat_capacity": 2.0,  "conductivity": 0.4,   "initial_temp": 293.15, "ignition_temp": 520.0, "burn_to": Id.FIRE },
	Id.OIL:   { "heat_capacity": 1.6,  "conductivity": 0.15,  "initial_temp": 293.15, "ignition_temp": 500.0, "burn_to": Id.FIRE },
	Id.SMOKE: { "heat_capacity": 0.05, "conductivity": 0.03,  "initial_temp": 400.0 },
	Id.WOOD:  { "heat_capacity": 1.0,  "conductivity": 0.15,  "initial_temp": 293.15, "ignition_temp": 570.0, "burn_to": Id.FIRE },
	# Tranche A provisional values; the thermal worker owns tuning these.
	Id.ICE:   { "heat_capacity": 2.1,  "conductivity": 2.2,   "initial_temp": 263.15, "hot_at": 273.15, "hot_to": Id.WATER, "latent": 80.0 },
	Id.LAVA:  { "heat_capacity": 3.0,  "conductivity": 1.5,   "initial_temp": 1500.0, "cold_at": 1000.0, "cold_to": Id.STONE, "latent": 300.0 },
	Id.STONE: { "heat_capacity": 2.1,  "conductivity": 1.5,   "initial_temp": 293.15, "hot_at": 1300.0, "hot_to": Id.LAVA, "latent": 300.0 },
	Id.METAL: { "heat_capacity": 3.5,  "conductivity": 50.0,  "initial_temp": 293.15 },
	# Tranche B.
	Id.WAX:        { "heat_capacity": 1.8, "conductivity": 0.25, "initial_temp": 293.15, "hot_at": 330.0, "hot_to": Id.MOLTEN_WAX, "latent": 50.0 },
	Id.MOLTEN_WAX: { "heat_capacity": 2.0, "conductivity": 0.2,  "initial_temp": 340.0,  "cold_at": 325.0, "cold_to": Id.WAX, "latent": 50.0, "ignition_temp": 640.0, "burn_to": Id.FIRE },
	Id.GUNPOWDER:  { "heat_capacity": 1.2, "conductivity": 0.2,  "initial_temp": 293.15, "ignition_temp": 420.0, "burn_to": Id.FIRE },
	Id.GAS:        { "heat_capacity": 0.05, "conductivity": 0.03, "initial_temp": 293.15, "ignition_temp": 500.0, "burn_to": Id.FIRE },
	Id.ACID:       { "heat_capacity": 3.0, "conductivity": 0.5,  "initial_temp": 293.15 },
	Id.CLONE:      { "heat_capacity": 2.1, "conductivity": 0.5,  "initial_temp": 293.15 },
	Id.VOID:       { "heat_capacity": 2.1, "conductivity": 0.0,  "initial_temp": 293.15 },
}

const THERMAL_DEFAULTS := {
	"heat_capacity": 1.0, "conductivity": 0.1, "initial_temp": 293.15, "fire_temp": 0.0,
	"ignition_temp": 0.0, "hot_at": 0.0, "hot_to": 0, "cold_at": 0.0, "cold_to": 0, "latent": 0.0, "burn_to": 0,
}


## Thermal coefficient `key` for element `id`, falling back to the declared default.
static func thermal(id: int, key: String) -> float:
	var row: Dictionary = THERMAL.get(id, {})
	return float(row.get(key, TABLE[id].get(key, THERMAL_DEFAULTS[key])))


## Schema validation used by the unit tests; returns a list of problems.
static func validate() -> PackedStringArray:
	var problems := PackedStringArray()
	for i in TABLE.size():
		var e: Dictionary = TABLE[i]
		if not CATEGORIES.has(e.get("category", "")):
			problems.append("%s: missing or unknown category" % e["name"])
		if String(e.get("tip", "")).is_empty():
			problems.append("%s: missing tip" % e["name"])
		if int(e["decay_to"]) >= TABLE.size():
			problems.append("%s: decay_to out of range" % e["name"])
		if thermal(i, "heat_capacity") <= 0.0:
			problems.append("%s: heat_capacity must be positive" % e["name"])
		for key in ["hot_to", "cold_to", "burn_to"]:
			if int(thermal(i, key)) >= TABLE.size():
				problems.append("%s: %s out of range" % [e["name"], key])
		if thermal(i, "hot_at") > 0.0 and thermal(i, "cold_at") > 0.0 and thermal(i, "cold_at") >= thermal(i, "hot_at"):
			problems.append("%s: cold_at must be below hot_at" % e["name"])
	for r in REACTIONS:
		if r.size() == 6 and not (r[5] is Dictionary):
			problems.append("reaction %s: sixth entry must be a dictionary" % str(r))
	return problems


## Pair reactions between axis-adjacent voxels: [a, b, out_a, out_b, probability].
## Checked both ways round; out_a replaces the `a` side, out_b the `b` side.
const REACTIONS := [
	[Id.FIRE, Id.PLANT, Id.FIRE, Id.FIRE, 0.5],   # plant catches fire
	[Id.FIRE, Id.OIL, Id.FIRE, Id.FIRE, 0.5],     # oil ignites
	[Id.FIRE, Id.WOOD, Id.FIRE, Id.FIRE, 0.08],   # wood burns, slowly
	[Id.FIRE, Id.WATER, Id.AIR, Id.STEAM, 1.0],   # water puts fire out and boils
	[Id.PLANT, Id.WATER, Id.PLANT, Id.PLANT, 0.0015], # plant drinks water and grows (slowly)
	# Heat milestone. `heat` is released into the pair once thermal lands; `cost`
	# is liquid consumed (amount units) from a liquid input that survives unchanged.
	[Id.FIRE, Id.GAS, Id.FIRE, Id.FIRE, 1.0, { "heat": 400.0 }],          # gas flashes
	# Gunpowder ignites through the fuse rule in sim.glsl (rule_special), not a
	# pair rule: a pair rule turned the touched grain into fire that rose away
	# before the next grain shared a block with it. Heat release ~600 K per cell.
	[Id.FIRE, Id.WAX, Id.FIRE, Id.MOLTEN_WAX, 0.05],   # interim contact melt until rule_phase lands
	[Id.FIRE, Id.MOLTEN_WAX, Id.FIRE, Id.FIRE, 0.02, { "heat": 120.0 }], # candle: molten wax feeds the flame
	[Id.ACID, Id.SAND, Id.ACID, Id.SMOKE, 0.3, { "cost": 40 }],
	[Id.ACID, Id.PLANT, Id.ACID, Id.SMOKE, 0.3, { "cost": 40 }],
	[Id.ACID, Id.WOOD, Id.ACID, Id.SMOKE, 0.15, { "cost": 50 }],
	[Id.ACID, Id.ICE, Id.ACID, Id.SMOKE, 0.2, { "cost": 40 }],
	[Id.ACID, Id.WAX, Id.ACID, Id.SMOKE, 0.2, { "cost": 40 }],
	[Id.ACID, Id.GUNPOWDER, Id.ACID, Id.SMOKE, 0.3, { "cost": 40 }],
	[Id.ACID, Id.STONE, Id.ACID, Id.SMOKE, 0.05, { "cost": 60 }],
	[Id.ACID, Id.METAL, Id.ACID, Id.SMOKE, 0.02, { "cost": 80 }],
]


static func count() -> int:
	return TABLE.size()


static func is_liquid(id: int) -> bool:
	return (TABLE[id]["flags"] & FLAG_LIQUID) != 0


## Amount byte a freshly created cell of this element carries.
static func default_amount(id: int) -> int:
	return LIQUID_FULL if is_liquid(id) else 0


## Bit per element id for shaders that need "is this a liquid" without the table.
static func liquid_mask() -> int:
	var mask := 0
	for id in TABLE.size():
		if is_liquid(id):
			mask |= 1 << id
	return mask


static func is_gas(id: int) -> bool:
	return (TABLE[id]["flags"] & FLAG_GAS) != 0


## Bit per element id for gases (air excluded: it is never drawn).
static func gas_mask() -> int:
	var mask := 0
	for id in range(1, TABLE.size()):
		if is_gas(id):
			mask |= 1 << id
	return mask


## Per-id volume opacity for the renderer (PALETTE_SIZE entries).
static func extinction() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(PALETTE_SIZE)
	for i in TABLE.size():
		out[i] = float(TABLE[i].get("extinction", 0.0))
	return out


static func palette() -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(PALETTE_SIZE)
	out.fill(Color(0, 0, 0, 0)) # unused ids stay fully transparent, not opaque black
	for i in TABLE.size():
		var c: Color = TABLE[i]["color"]
		c.a = float(TABLE[i].get("emission", 0.0))
		out[i] = c
	return out


## 80 bytes per element (std430: the trailing uvec4 is 16-byte aligned).
## First 32: uint flags (decay target in the high byte), float density, decay,
## spread, extinction, air_coupling, heat, smooth. Then thermal_a
## (heat_capacity, conductivity, initial_temp, fire_temp), thermal_b
## (ignition_temp, hot_at, cold_at, latent) and uvec4 ids
## (hot_to | cold_to << 8 | burn_to << 16, rest zero). Matches `struct Elem`
## in shaders/compute/elem.glslinc, whose ELEM_BYTES_SENTINEL must agree.
const ELEM_BYTES := 80
const ELEM_INCLUDE := "res://shaders/compute/elem.glslinc"

static func property_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(TABLE.size() * ELEM_BYTES)
	for i in TABLE.size():
		var e: Dictionary = TABLE[i]
		var base := i * ELEM_BYTES
		var flags: int = e["flags"] | (int(e["decay_to"]) << 24)
		out.encode_u32(base + 0, flags)
		out.encode_float(base + 4, e["density"])
		out.encode_float(base + 8, e["decay"])
		out.encode_float(base + 12, e["spread"])
		out.encode_float(base + 16, float(e.get("extinction", 0.0)))
		out.encode_float(base + 20, float(e.get("air_coupling", 0.0)))
		out.encode_float(base + 24, float(e.get("heat", 0.0)))
		out.encode_float(base + 28, float(e.get("smooth", 0.0)))
		out.encode_float(base + 32, thermal(i, "heat_capacity"))
		out.encode_float(base + 36, thermal(i, "conductivity"))
		out.encode_float(base + 40, thermal(i, "initial_temp"))
		out.encode_float(base + 44, thermal(i, "fire_temp"))
		out.encode_float(base + 48, thermal(i, "ignition_temp"))
		out.encode_float(base + 52, thermal(i, "hot_at"))
		out.encode_float(base + 56, thermal(i, "cold_at"))
		out.encode_float(base + 60, thermal(i, "latent"))
		var ids: int = int(thermal(i, "hot_to")) | (int(thermal(i, "cold_to")) << 8) | (int(thermal(i, "burn_to")) << 16)
		out.encode_u32(base + 64, ids)
		# base + 68 .. base + 79 reserved (ids.yzw), left zero.
	return out


## Texture layer per element id (PALETTE_SIZE entries, 3 = generic).
static func material_layers() -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(PALETTE_SIZE)
	out.fill(3)
	for i in TABLE.size():
		out[i] = int(TABLE[i].get("mat", 3))
	return out


## Any numeric per-element field as a PALETTE_SIZE float array.
static func floats(key: String, default := 0.0) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(PALETTE_SIZE)
	for i in TABLE.size():
		out[i] = float(TABLE[i].get(key, default))
	return out


## 16 bytes per reaction: packed ids (a | b<<8 | out_a<<16 | out_b<<24),
## probability as 16-bit fixed point in the low half of the second word with
## `cost` (liquid amount units consumed from a liquid input whose output is
## itself) in the high half, then min_t and heat as float bits, all from an
## optional sixth `{ "min_t": K, "heat": K per full cell, "cost": units }`
## dictionary (zero when absent). Matches `Reacts` in sim.glsl. One rule per unordered
## pair: the kernel stops at the first matching rule even when its roll fails,
## so table order decides which rule a pair gets.
static func reaction_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(maxi(REACTIONS.size(), 1) * 16)
	for i in REACTIONS.size():
		var r: Array = REACTIONS[i]
		var packed: int = int(r[0]) | (int(r[1]) << 8) | (int(r[2]) << 16) | (int(r[3]) << 24)
		out.encode_u32(i * 16 + 0, packed)
		var extra: Dictionary = r[5] if r.size() > 5 and r[5] is Dictionary else {}
		out.encode_u32(i * 16 + 4, int(clampf(r[4], 0.0, 1.0) * 65535.0) | (clampi(int(extra.get("cost", 0)), 0, 255) << 16))
		out.encode_float(i * 16 + 8, float(extra.get("min_t", 0.0)))
		out.encode_float(i * 16 + 12, float(extra.get("heat", 0.0)))
	return out
