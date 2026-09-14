class_name Scenarios
extends RefCounted
## Preset worlds. Each builder returns the full world as bytes. They double as
## living demos of the simulation milestones.

const GRID := VoxelCodec.GRID
const AIR := Elements.Id.AIR
const WALL := Elements.Id.WALL
const SAND := Elements.Id.SAND
const WATER := Elements.Id.WATER
const STEAM := Elements.Id.STEAM
const FIRE := Elements.Id.FIRE
const PLANT := Elements.Id.PLANT
const OIL := Elements.Id.OIL

const DEFAULT := "Demo"


static func names() -> PackedStringArray:
	return PackedStringArray(["Demo", "Dam break", "U-bend", "Pressure pipe", "Forest fire", "Oil spill", "Steam vent", "Empty"])


static func build(name: String) -> PackedByteArray:
	var data := WorldBuilder.empty()
	match name:
		"Dam break": _dam_break(data)
		"U-bend": _u_bend(data)
		"Pressure pipe": _pressure_pipe(data)
		"Forest fire": _forest_fire(data)
		"Oil spill": _oil_spill(data)
		"Steam vent": _steam_vent(data)
		"Empty": WorldBuilder.floor(data)
		_: _demo(data)
	return data.to_byte_array()


## A bit of everything: sand pile, bowl catching a water cube, steam, a tree
## that catches fire, an oil pool.
static func _demo(data: PackedInt32Array) -> void:
	WorldBuilder.floor(data)
	WorldBuilder.fill_sphere(data, Vector3(GRID * 0.5, GRID * 0.55, GRID * 0.5), GRID * 0.2, SAND)
	WorldBuilder.fill_bowl(data, Vector3i(4, 0, 4), Vector3i(44, 30, 44))
	WorldBuilder.fill_box(data, Vector3i(10, 60, 10), Vector3i(34, 84, 34), WATER)
	WorldBuilder.fill_box(data, Vector3i(84, 8, 8), Vector3i(104, 28, 28), STEAM)
	_tree(data, Vector3i(106, 4, 106), 36, 12, 36)
	WorldBuilder.fill_box(data, Vector3i(96, 4, 100), Vector3i(100, 8, 112), FIRE)
	WorldBuilder.fill_box(data, Vector3i(50, 4, 100), Vector3i(62, 16, 124), OIL)


## A reservoir held back by a wall with a notch already cut in it.
static func _dam_break(data: PackedInt32Array) -> void:
	WorldBuilder.floor(data)
	WorldBuilder.fill_box(data, Vector3i(60, 4, 0), Vector3i(64, 70, GRID), WALL)      # dam
	WorldBuilder.fill_box(data, Vector3i(60, 4, 52), Vector3i(64, 30, 76), AIR)        # breach
	WorldBuilder.fill_box(data, Vector3i(2, 4, 2), Vector3i(60, 60, GRID - 2), WATER)  # reservoir
	WorldBuilder.fill_sphere(data, Vector3(100, 12, 40), 10.0, SAND)                   # downstream pile
	_tree(data, Vector3i(104, 4, 90), 24, 6, 24)


## One arm filled; water finds its level through the bottom channel.
static func _u_bend(data: PackedInt32Array) -> void:
	WorldBuilder.floor(data)
	WorldBuilder.fill_box(data, Vector3i(20, 4, 44), Vector3i(108, 100, 84), WALL)
	WorldBuilder.fill_box(data, Vector3i(26, 10, 50), Vector3i(42, 100, 78), AIR)     # left arm
	WorldBuilder.fill_box(data, Vector3i(86, 10, 50), Vector3i(102, 100, 78), AIR)    # right arm
	WorldBuilder.fill_box(data, Vector3i(26, 10, 50), Vector3i(102, 18, 78), AIR)     # channel
	WorldBuilder.fill_box(data, Vector3i(26, 18, 50), Vector3i(42, 90, 78), WATER)


## An open tank feeds a narrow riser outside it; water climbs to the tank level.
static func _pressure_pipe(data: PackedInt32Array) -> void:
	WorldBuilder.floor(data)
	WorldBuilder.fill_bowl(data, Vector3i(20, 4, 30), Vector3i(76, 80, 86), 3)
	WorldBuilder.fill_box(data, Vector3i(23, 7, 33), Vector3i(73, 60, 83), WATER)
	WorldBuilder.fill_box(data, Vector3i(76, 4, 52), Vector3i(92, 100, 64), WALL)      # riser casing
	WorldBuilder.fill_box(data, Vector3i(73, 7, 56), Vector3i(86, 10, 60), AIR)        # floor channel
	WorldBuilder.fill_box(data, Vector3i(82, 7, 56), Vector3i(86, 100, 60), AIR)       # riser


## A grove on sand with undergrowth to carry the fire, and a spark at one trunk.
static func _forest_fire(data: PackedInt32Array) -> void:
	WorldBuilder.floor(data)
	WorldBuilder.fill_box(data, Vector3i(0, 4, 0), Vector3i(GRID, 7, GRID), SAND)
	WorldBuilder.fill_box(data, Vector3i(4, 7, 4), Vector3i(GRID - 4, 8, GRID - 4), PLANT)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var first := Vector3i.ZERO
	for i in 14:
		var x := rng.randi_range(12, GRID - 20)
		var z := rng.randi_range(12, GRID - 20)
		var h := rng.randi_range(22, 40)
		var w := rng.randi_range(14, 24)
		_tree(data, Vector3i(x, 8, z), h, 5, w)
		if i == 0:
			first = Vector3i(x, 8, z)
	# Spark against the first trunk so the blaze starts immediately.
	WorldBuilder.fill_box(data, first + Vector3i(3, 0, -2), first + Vector3i(7, 6, 2), FIRE)


## Oil dropped into a pool of water floats, then meets a flame.
static func _oil_spill(data: PackedInt32Array) -> void:
	WorldBuilder.floor(data)
	WorldBuilder.fill_bowl(data, Vector3i(14, 0, 14), Vector3i(114, 40, 114), 3)
	WorldBuilder.fill_box(data, Vector3i(17, 4, 17), Vector3i(111, 26, 111), WATER)
	WorldBuilder.fill_sphere(data, Vector3(64, 70, 64), 16.0, OIL)
	WorldBuilder.fill_box(data, Vector3i(100, 26, 100), Vector3i(106, 30, 106), FIRE)


## A pool with embers underneath: it boils, steam rises and rains back down.
static func _steam_vent(data: PackedInt32Array) -> void:
	WorldBuilder.floor(data)
	WorldBuilder.fill_bowl(data, Vector3i(30, 0, 30), Vector3i(98, 50, 98), 3)
	WorldBuilder.fill_box(data, Vector3i(33, 4, 33), Vector3i(95, 12, 95), FIRE)
	WorldBuilder.fill_box(data, Vector3i(33, 12, 33), Vector3i(95, 36, 95), WATER)


## Trunk plus a blocky canopy; face-connected so fire can climb it.
static func _tree(data: PackedInt32Array, base: Vector3i, height: int, trunk: int, canopy: int) -> void:
	var half_t := trunk / 2
	var half_c := canopy / 2
	WorldBuilder.fill_box(data, Vector3i(base.x - half_t, base.y, base.z - half_t),
		Vector3i(base.x + half_t, base.y + height, base.z + half_t), PLANT)
	var top := base.y + height
	WorldBuilder.fill_box(data, Vector3i(base.x - half_c, top - 4, base.z - half_c),
		Vector3i(base.x + half_c, top + 4, base.z + half_c), PLANT)
	WorldBuilder.fill_box(data, Vector3i(base.x - half_c / 2, top + 4, base.z - half_c / 2),
		Vector3i(base.x + half_c / 2, top + 8, base.z + half_c / 2), PLANT)
