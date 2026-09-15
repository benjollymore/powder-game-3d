class_name Scenarios
extends RefCounted
## Preset worlds. Each builder returns the full world as bytes. They double as
## living demos of the simulation milestones.
##
## Scenarios are authored in a 128-voxel reference box and scaled to the
## actual grid, so a 256^3 world gets the same layout at twice the resolution.

const AIR := Elements.Id.AIR
const WALL := Elements.Id.WALL
const SAND := Elements.Id.SAND
const WATER := Elements.Id.WATER
const STEAM := Elements.Id.STEAM
const FIRE := Elements.Id.FIRE
const PLANT := Elements.Id.PLANT
const OIL := Elements.Id.OIL
const WOOD := Elements.Id.WOOD
const WAX := Elements.Id.WAX
const GUNPOWDER := Elements.Id.GUNPOWDER
const ACID := Elements.Id.ACID
const CLONE := Elements.Id.CLONE
const VOID := Elements.Id.VOID

const DEFAULT := "Demo"
## Reference box the coordinates below are written in.
const REF := 128


static func names() -> PackedStringArray:
	return PackedStringArray(["Demo", "Dam break", "U-bend", "Pressure pipe", "Forest fire", "Oil spill", "Steam vent", "Candle", "Powder keg", "Acid rain", "Empty"])


## Primitive ops (already scaled to the grid) that make up a scenario.
## Each is {"type": "box", "lo", "hi", "id", "amount"} or
## {"type": "sphere", "center", "radius", "id", "amount"}. The sim replays them
## on the GPU; `build` replays them on the CPU for tests.
static var _ops: Array = []


static func ops(name: String) -> Array:
	_ops = []
	var data := PackedInt32Array()
	match name:
		"Dam break": _dam_break(data)
		"U-bend": _u_bend(data)
		"Pressure pipe": _pressure_pipe(data)
		"Forest fire": _forest_fire(data)
		"Oil spill": _oil_spill(data)
		"Steam vent": _steam_vent(data)
		"Candle": _candle(data)
		"Powder keg": _powder_keg(data)
		"Acid rain": _acid_rain(data)
		"Empty": _floor(data)
		_: _demo(data)
	var out := _ops
	_ops = []
	return out


static func build(name: String) -> PackedByteArray:
	var data := WorldBuilder.empty()
	for op in ops(name):
		if op["type"] == "box":
			WorldBuilder.fill_box(data, op["lo"], op["hi"], op["id"], op["amount"])
		else:
			WorldBuilder.fill_sphere(data, op["center"], op["radius"], op["id"], op["amount"])
	return data.to_byte_array()


## A bit of everything: sand pile, bowl catching a water cube, steam, a tree
## that catches fire, an oil pool.
static func _demo(data: PackedInt32Array) -> void:
	_floor(data)
	_sphere(data, Vector3(REF * 0.5, REF * 0.55, REF * 0.5), REF * 0.2, SAND)
	_bowl(data, Vector3i(4, 0, 4), Vector3i(44, 30, 44))
	_box(data, Vector3i(10, 60, 10), Vector3i(34, 84, 34), WATER)
	_box(data, Vector3i(84, 8, 8), Vector3i(104, 28, 28), STEAM)
	_tree(data, Vector3i(106, 4, 106), 36, 12, 36)
	_box(data, Vector3i(96, 4, 100), Vector3i(100, 8, 112), FIRE)
	_box(data, Vector3i(50, 4, 100), Vector3i(62, 16, 124), OIL)


## A reservoir held back by a wall with a notch already cut in it.
static func _dam_break(data: PackedInt32Array) -> void:
	_floor(data)
	_box(data, Vector3i(60, 4, 0), Vector3i(64, 70, REF), WALL)      # dam
	_box(data, Vector3i(60, 4, 52), Vector3i(64, 30, 76), AIR)        # breach
	_box(data, Vector3i(2, 4, 2), Vector3i(60, 60, REF - 2), WATER)  # reservoir
	_sphere(data, Vector3(100, 12, 40), 10.0, SAND)                   # downstream pile
	_tree(data, Vector3i(104, 4, 90), 24, 6, 24)


## One arm filled; water finds its level through the bottom channel.
static func _u_bend(data: PackedInt32Array) -> void:
	_floor(data)
	_box(data, Vector3i(20, 4, 44), Vector3i(108, 100, 84), WALL)
	_box(data, Vector3i(26, 10, 50), Vector3i(42, 100, 78), AIR)     # left arm
	_box(data, Vector3i(86, 10, 50), Vector3i(102, 100, 78), AIR)    # right arm
	_box(data, Vector3i(26, 10, 50), Vector3i(102, 18, 78), AIR)     # channel
	_box(data, Vector3i(26, 18, 50), Vector3i(42, 90, 78), WATER)


## An open tank feeds a narrow riser outside it; water climbs to the tank level.
static func _pressure_pipe(data: PackedInt32Array) -> void:
	_floor(data)
	_bowl(data, Vector3i(20, 4, 30), Vector3i(76, 80, 86), 3)
	_box(data, Vector3i(23, 7, 33), Vector3i(73, 60, 83), WATER)
	_box(data, Vector3i(76, 4, 52), Vector3i(92, 100, 64), WALL)      # riser casing
	_box(data, Vector3i(73, 7, 56), Vector3i(86, 10, 60), AIR)        # floor channel
	_box(data, Vector3i(82, 7, 56), Vector3i(86, 100, 60), AIR)       # riser


## A grove on sand with undergrowth to carry the fire, and a spark at one trunk.
static func _forest_fire(data: PackedInt32Array) -> void:
	_floor(data)
	_box(data, Vector3i(0, 4, 0), Vector3i(REF, 7, REF), SAND)
	_box(data, Vector3i(4, 7, 4), Vector3i(REF - 4, 8, REF - 4), PLANT)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var first := Vector3i.ZERO
	for i in 14:
		var x := rng.randi_range(12, REF - 20)
		var z := rng.randi_range(12, REF - 20)
		var h := rng.randi_range(22, 40)
		var w := rng.randi_range(14, 24)
		_tree(data, Vector3i(x, 8, z), h, 5, w)
		if i == 0:
			first = Vector3i(x, 8, z)
	# Spark against the first trunk so the blaze starts immediately.
	_box(data, first + Vector3i(3, 0, -2), first + Vector3i(7, 6, 2), FIRE)


## Oil dropped into a pool of water floats, then meets a flame.
static func _oil_spill(data: PackedInt32Array) -> void:
	_floor(data)
	_bowl(data, Vector3i(14, 0, 14), Vector3i(114, 40, 114), 3)
	_box(data, Vector3i(17, 3, 17), Vector3i(111, 26, 111), WATER)   # rests on the bowl floor: no trapped air
	_sphere(data, Vector3(64, 70, 64), 16.0, OIL)
	_box(data, Vector3i(100, 26, 100), Vector3i(106, 30, 106), FIRE)


## A pool with embers underneath: it boils, steam rises and rains back down.
static func _steam_vent(data: PackedInt32Array) -> void:
	_floor(data)
	_bowl(data, Vector3i(30, 0, 30), Vector3i(98, 50, 98), 3)
	_box(data, Vector3i(33, 3, 33), Vector3i(95, 12, 95), FIRE)
	_box(data, Vector3i(33, 12, 33), Vector3i(95, 36, 95), WATER)


## A wax pillar with a flame on top: it melts, runs down and sets again.
static func _candle(data: PackedInt32Array) -> void:
	_floor(data)
	_box(data, Vector3i(56, 4, 56), Vector3i(72, 44, 72), WAX)
	_box(data, Vector3i(60, 44, 60), Vector3i(68, 50, 68), FIRE)


## A gunpowder trail from a spark to a keg standing beside an oil pool.
static func _powder_keg(data: PackedInt32Array) -> void:
	_floor(data)
	_box(data, Vector3i(10, 4, 60), Vector3i(92, 6, 64), GUNPOWDER)        # trail
	_bowl(data, Vector3i(88, 4, 48), Vector3i(112, 30, 76), 2)             # keg
	_box(data, Vector3i(90, 6, 50), Vector3i(110, 26, 74), GUNPOWDER)
	_box(data, Vector3i(88, 4, 60), Vector3i(90, 8, 64), GUNPOWDER)        # trail enters the keg
	_bowl(data, Vector3i(30, 4, 80), Vector3i(110, 24, 124), 3)            # oil pool
	_box(data, Vector3i(33, 7, 83), Vector3i(107, 18, 121), OIL)
	_box(data, Vector3i(6, 4, 58), Vector3i(10, 8, 66), FIRE)              # spark


## A clone tray drips acid onto a layered pile; a void floor drains the runoff.
static func _acid_rain(data: PackedInt32Array) -> void:
	_floor(data)
	_box(data, Vector3i(6, 4, 6), Vector3i(REF - 6, 5, REF - 6), VOID)     # drain
	_box(data, Vector3i(40, 4, 40), Vector3i(88, 8, 88), WALL)             # platform
	_box(data, Vector3i(42, 8, 42), Vector3i(86, 20, 86), SAND)
	_box(data, Vector3i(42, 20, 42), Vector3i(86, 30, 86), WOOD)
	_box(data, Vector3i(42, 30, 42), Vector3i(86, 40, 86), SAND)
	_box(data, Vector3i(52, 102, 52), Vector3i(76, 104, 76), WALL)         # cap
	_box(data, Vector3i(52, 100, 52), Vector3i(76, 102, 76), CLONE)        # tray
	_box(data, Vector3i(52, 99, 52), Vector3i(76, 100, 76), ACID)          # seed


## Wood trunk with a canopy of overlapping plant spheres; face-connected so
## fire can climb it. Leaf cards grow on the plant (see splat_emit.glsl).
static func _tree(data: PackedInt32Array, base: Vector3i, height: int, trunk: int, canopy: int) -> void:
	var half_t := trunk / 2
	var r := canopy * 0.5
	var top := base.y + height
	var c := Vector3(base.x, top, base.z)
	_box(data, Vector3i(base.x - half_t, base.y, base.z - half_t),
		Vector3i(base.x + half_t, top - int(r * 0.4), base.z + half_t), WOOD)
	_sphere(data, c, r, PLANT)
	var seed := base.x * 31 + base.z * 17 + height
	var lobes := [Vector3(0.55, 0.15, 0.1), Vector3(-0.4, 0.3, 0.45), Vector3(0.05, 0.45, -0.5), Vector3(-0.3, -0.1, -0.35)]
	for i in lobes.size():
		var l: Vector3 = lobes[(i + seed) % lobes.size()]
		_sphere(data, c + l * r, r * (0.55 + 0.1 * float((seed >> i) & 1)), PLANT)


# --- reference-unit primitives ------------------------------------------------

static func _k() -> float:
	return float(VoxelCodec.GRID) / float(REF)


static func _sc(v: Vector3i) -> Vector3i:
	return Vector3i((Vector3(v) * _k()).round())


static func _box(_data: PackedInt32Array, lo: Vector3i, hi: Vector3i, id: int, amount: int = -1) -> void:
	if amount < 0:
		amount = Elements.default_amount(id)
	_ops.append({"type": "box", "lo": _sc(lo), "hi": _sc(hi), "id": id, "amount": amount})


static func _sphere(_data: PackedInt32Array, center: Vector3, radius: float, id: int, amount: int = -1) -> void:
	if amount < 0:
		amount = Elements.default_amount(id)
	_ops.append({"type": "sphere", "center": center * _k(), "radius": radius * _k(), "id": id, "amount": amount})


static func _bowl(data: PackedInt32Array, lo: Vector3i, hi: Vector3i, wall := 2) -> void:
	var w := maxi(1, int(round(wall * _k())))
	var a := _sc(lo)
	var b := _sc(hi)
	_ops.append({"type": "box", "lo": a, "hi": b, "id": WALL, "amount": 0})
	_ops.append({"type": "box", "lo": a + Vector3i(w, w, w), "hi": Vector3i(b.x - w, b.y, b.z - w), "id": AIR, "amount": 0})


static func _floor(data: PackedInt32Array) -> void:
	var h := maxi(1, int(round(4 * _k())))
	_ops.append({"type": "box", "lo": Vector3i.ZERO, "hi": Vector3i(VoxelCodec.GRID, h, VoxelCodec.GRID), "id": WALL, "amount": 0})
