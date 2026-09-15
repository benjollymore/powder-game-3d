extends RefCounted
## Pure editing geometry, independent of simulation storage or rendering.

## Workplane target (placement-brief contract 2): the cell whose visible face
## the ray crosses. The plane is the one-cell slab `[cell, cell + 1)` along
## `axis`; the ray's entry point into that slab (or the origin, when the camera
## is already inside it) is floored on the other two axes. A ray perpendicular
## to the plane gets the same cell as the old centre-plane intersection; a
## grazing ray no longer lands cells away from the face under the pointer.
static func target(origin: Vector3, direction: Vector3, axis: int, cell: int, grid: int) -> Vector3i:
	if absf(direction[axis]) < 0.000001:
		return Vector3i(-1, -1, -1)
	var lo := float(cell) / grid - 0.5
	var hi := float(cell + 1) / grid - 0.5
	var t_lo := (lo - origin[axis]) / direction[axis]
	var t_hi := (hi - origin[axis]) / direction[axis]
	var t_exit := maxf(t_lo, t_hi)
	if t_exit < 0.0:
		return Vector3i(-1, -1, -1)
	var t := maxf(minf(t_lo, t_hi), 0.0)
	# Nudge along the ray so a hit exactly on a lateral cell edge floors into
	# the cell the ray is entering, as the GPU pick kernel does.
	var p := (origin + direction * t + Vector3.ONE * 0.5) * grid + direction * 0.0001
	var result := Vector3i(p.floor())
	result[axis] = cell
	for a in 3:
		if result[a] < 0 or result[a] >= grid:
			return Vector3i(-1, -1, -1)
	return result


## Face-connected digital line, including both endpoints. Even radius 0 has no
## gaps. Stamps intentionally overcover diagonal crossings by at most one cell.
static func stroke(a: Vector3i, b: Vector3i) -> Array[Vector3i]:
	var result: Array[Vector3i] = [a]
	var delta := (b - a).abs()
	var count := maxi(delta.x, maxi(delta.y, delta.z))
	var current := a
	for i in range(1, count + 1):
		var next := Vector3i(Vector3(a).lerp(Vector3(b), float(i) / count).round())
		for axis in 3:
			while current[axis] != next[axis]:
				current[axis] += 1 if next[axis] > current[axis] else -1
				result.append(current)
	return result
