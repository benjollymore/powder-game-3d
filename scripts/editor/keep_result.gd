extends RefCounted
## CPU side of "Keep result as build": which history tiles differ between the
## authored snapshot and the live experiment, and whether that fits one
## regional transaction. Rows are compared as slices so an unchanged world
## costs one comparison per row, not one per cell.

static func changed_tiles(before: PackedByteArray, after: PackedByteArray, grid: int, tile: int, bytes_per_cell: int = 4, seen: Dictionary = {}) -> Array[Vector3i]:
	var tiles: Array[Vector3i] = []
	if before.size() != after.size() or before.size() != grid * grid * grid * bytes_per_cell:
		return tiles
	var row_bytes := grid * bytes_per_cell
	var chunk := tile * bytes_per_cell
	for z in grid:
		for y in grid:
			var start := (z * grid + y) * row_bytes
			if before.slice(start, start + row_bytes) == after.slice(start, start + row_bytes):
				continue
			var tz := z / tile
			var ty := y / tile
			for tx in ceili(float(grid) / tile):
				var key := Vector3i(tx, ty, tz)
				if seen.has(key):
					continue
				var a := start + tx * chunk
				if before.slice(a, a + chunk) != after.slice(a, a + chunk):
					seen[key] = true
					tiles.append(key)
	tiles.sort()
	return tiles


## Tiles where either the voxel layer or the thermal layer differs.
static func changed_tiles_all(before: Dictionary, after: Dictionary, grid: int, tile: int) -> Array[Vector3i]:
	var seen := {}
	var tiles: Array[Vector3i] = changed_tiles(before.voxels, after.voxels, grid, tile, 4, seen)
	if before.has("thermal") and after.has("thermal") and not before.thermal.is_empty():
		tiles.append_array(changed_tiles(before.thermal, after.thermal, grid, tile, 8, seen))
	tiles.sort()
	return tiles


## Aligned tile bounds in the layout the editor's regional history uses.
static func bounds(tiles: Array[Vector3i], grid: int, tile: int) -> Array:
	var result: Array = []
	for key in tiles:
		var lo := key * tile
		result.append({"lo": lo, "hi": (lo + Vector3i.ONE * tile).min(Vector3i.ONE * grid)})
	return result


static func byte_count(tiles: Array[Vector3i], grid: int, tile: int, bytes_per_cell: int = 12) -> int:
	var total := 0
	for region in bounds(tiles, grid, tile):
		var extent: Vector3i = region.hi - region.lo
		total += extent.x * extent.y * extent.z * bytes_per_cell
	return total
