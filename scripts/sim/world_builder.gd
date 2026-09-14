class_name WorldBuilder
extends RefCounted
## Builds world byte arrays from simple primitives. Used by scenarios and tests.
## Fills only the voxels they touch, so even large worlds build in milliseconds.



static func empty() -> PackedInt32Array:
	var data := PackedInt32Array()
	data.resize(VoxelCodec.GRID * VoxelCodec.GRID * VoxelCodec.GRID)
	return data


## Deterministic per-voxel seed for colour variation.
static func seed_at(x: int, y: int, z: int) -> int:
	return (x * 7 + y * 13 + z * 31) & 0xFF


## Fill [lo, hi) with an element. `amount` < 0 uses the element's default.
static func fill_box(data: PackedInt32Array, lo: Vector3i, hi: Vector3i, id: int, amount: int = -1) -> void:
	if amount < 0:
		amount = Elements.default_amount(id)
	var a := lo.clamp(Vector3i.ZERO, Vector3i(VoxelCodec.GRID, VoxelCodec.GRID, VoxelCodec.GRID))
	var b := hi.clamp(Vector3i.ZERO, Vector3i(VoxelCodec.GRID, VoxelCodec.GRID, VoxelCodec.GRID))
	for z in range(a.z, b.z):
		for y in range(a.y, b.y):
			for x in range(a.x, b.x):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, seed_at(x, y, z), amount)


static func fill_sphere(data: PackedInt32Array, center: Vector3, radius: float, id: int, amount: int = -1) -> void:
	if amount < 0:
		amount = Elements.default_amount(id)
	var r2 := radius * radius
	var lo := Vector3i((center - Vector3.ONE * radius).floor()).clamp(Vector3i.ZERO, Vector3i(VoxelCodec.GRID, VoxelCodec.GRID, VoxelCodec.GRID))
	var hi := Vector3i((center + Vector3.ONE * radius).ceil() + Vector3.ONE).clamp(Vector3i.ZERO, Vector3i(VoxelCodec.GRID, VoxelCodec.GRID, VoxelCodec.GRID))
	for z in range(lo.z, hi.z):
		for y in range(lo.y, hi.y):
			for x in range(lo.x, hi.x):
				if Vector3(x, y, z).distance_squared_to(center) < r2:
					data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, seed_at(x, y, z), amount)


## A box of walls with a hollow interior open at the top (a tank or bowl).
static func fill_bowl(data: PackedInt32Array, lo: Vector3i, hi: Vector3i, wall := 2) -> void:
	fill_box(data, lo, hi, Elements.Id.WALL)
	fill_box(data, lo + Vector3i(wall, wall, wall), Vector3i(hi.x - wall, hi.y, hi.z - wall), Elements.Id.AIR)


## Floor slab across the whole world.
static func floor(data: PackedInt32Array, height := 4) -> void:
	fill_box(data, Vector3i.ZERO, Vector3i(VoxelCodec.GRID, height, VoxelCodec.GRID), Elements.Id.WALL)
