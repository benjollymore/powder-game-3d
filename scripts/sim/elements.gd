class_name Elements
extends RefCounted
## Single source of truth for elements. Feeds the renderer palette, the
## compute-shader property buffer (M3+), and the palette UI (M4+).
## Adding an element = one row in TABLE (+ shader code only if it needs
## bespoke behaviour).

enum Id { AIR, WALL, SAND, WATER, STEAM, FIRE, PLANT, OIL }

const FLAG_IMMOVABLE := 1 << 0
const FLAG_POWDER := 1 << 1
const FLAG_LIQUID := 1 << 2
const FLAG_GAS := 1 << 3
const FLAG_FLAMMABLE := 1 << 4

## Renderer palette slots; keep in sync with `palette[16]` in the shader.
const PALETTE_SIZE := 16

## Index = Id. density: lighter things rise through heavier ones.
## decay: per-tick chance to turn into `decay_to`. spread: sideways flow chance.
const TABLE := [
	{ "name": "Air",   "color": Color(0, 0, 0, 0),          "flags": FLAG_GAS,                     "density": 10.0,   "decay": 0.0,  "decay_to": 0, "spread": 0.0 },
	{ "name": "Wall",  "color": Color(0.45, 0.45, 0.48),    "flags": FLAG_IMMOVABLE,               "density": 1000.0, "decay": 0.0,  "decay_to": 0, "spread": 0.0 },
	{ "name": "Sand",  "color": Color(0.86, 0.72, 0.42),    "flags": FLAG_POWDER,                  "density": 200.0,  "decay": 0.0,  "decay_to": 0, "spread": 0.0 },
	{ "name": "Water", "color": Color(0.2, 0.45, 0.9),      "flags": FLAG_LIQUID,                  "density": 100.0,  "decay": 0.0,  "decay_to": 0, "spread": 1.0 },
	{ "name": "Steam", "color": Color(0.8, 0.85, 0.9),      "flags": FLAG_GAS,                     "density": 1.0,    "decay": 0.0005, "decay_to": 3, "spread": 0.6 },
	{ "name": "Fire",  "color": Color(1.0, 0.45, 0.1),      "flags": FLAG_GAS,                     "density": 2.0,    "decay": 0.05, "decay_to": 0, "spread": 0.3, "emission": 2.2 },
	{ "name": "Plant", "color": Color(0.2, 0.7, 0.25),      "flags": FLAG_IMMOVABLE | FLAG_FLAMMABLE, "density": 1000.0, "decay": 0.0, "decay_to": 0, "spread": 0.0 },
	{ "name": "Oil",   "color": Color(0.35, 0.25, 0.15),    "flags": FLAG_LIQUID | FLAG_FLAMMABLE, "density": 80.0,   "decay": 0.0,  "decay_to": 0, "spread": 0.5 },
]


## Pair reactions between axis-adjacent voxels: [a, b, out_a, out_b, probability].
## Checked both ways round; out_a replaces the `a` side, out_b the `b` side.
const REACTIONS := [
	[Id.FIRE, Id.PLANT, Id.FIRE, Id.FIRE, 0.3],   # plant catches fire
	[Id.FIRE, Id.OIL, Id.FIRE, Id.FIRE, 0.5],     # oil ignites
	[Id.FIRE, Id.WATER, Id.AIR, Id.STEAM, 1.0],   # water puts fire out and boils
	[Id.PLANT, Id.WATER, Id.PLANT, Id.PLANT, 0.02], # plant drinks water and grows
]


static func count() -> int:
	return TABLE.size()


static func palette() -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(PALETTE_SIZE)
	for i in TABLE.size():
		var c: Color = TABLE[i]["color"]
		c.a = float(TABLE[i].get("emission", 0.0))
		out[i] = c
	return out


## 16 bytes per element: uint flags, float density, float decay, float spread
## (decay target packed into the high byte of flags). Matches `struct Elem` in sim.glsl.
static func property_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(TABLE.size() * 16)
	for i in TABLE.size():
		var e: Dictionary = TABLE[i]
		var flags: int = e["flags"] | (int(e["decay_to"]) << 24)
		out.encode_u32(i * 16 + 0, flags)
		out.encode_float(i * 16 + 4, e["density"])
		out.encode_float(i * 16 + 8, e["decay"])
		out.encode_float(i * 16 + 12, e["spread"])
	return out


## 16 bytes per reaction: packed ids (a | b<<8 | out_a<<16 | out_b<<24),
## probability as 16-bit fixed point, two unused. Matches `Reacts` in sim.glsl.
static func reaction_bytes() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(maxi(REACTIONS.size(), 1) * 16)
	for i in REACTIONS.size():
		var r: Array = REACTIONS[i]
		var packed: int = int(r[0]) | (int(r[1]) << 8) | (int(r[2]) << 16) | (int(r[3]) << 24)
		out.encode_u32(i * 16 + 0, packed)
		out.encode_u32(i * 16 + 4, int(clampf(r[4], 0.0, 1.0) * 65535.0))
	return out
