extends RefCounted
## Pure editing geometry, independent of simulation storage or rendering.

static func target(origin: Vector3, direction: Vector3, axis: int, cell: int, grid: int) -> Vector3i:
	if absf(direction[axis]) < 0.000001:
		return Vector3i(-1, -1, -1)
	var plane := (float(cell) + 0.5) / grid - 0.5
	var t := (plane - origin[axis]) / direction[axis]
	if t < 0.0:
		return Vector3i(-1, -1, -1)
	var p := (origin + direction * t + Vector3.ONE * 0.5) * grid
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
