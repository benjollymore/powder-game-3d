extends RefCounted
## Stamp spacing for heat and cool strokes. A stroke is a path of cells; the
## brush sphere is stamped only where the path has moved at least `radius`
## cells (at least one) from the previous stamp, so a slow drag and a fast
## drag over the same path deposit the same heat. Shared by the editor's
## workplane strokes and the simulator's surface-picked strokes.

static func spacing(radius: int) -> int:
	return maxi(1, radius)


## Returns the cells to stamp, in order, given the previous stamp (x < 0
## when none). `last` is updated in place through the returned dictionary.
static func select(cells: Array[Vector3i], radius: int, last: Vector3i) -> Dictionary:
	var out: Array[Vector3i] = []
	var gap := spacing(radius)
	var threshold := gap * gap
	var previous := last
	for cell in cells:
		if previous.x < 0 or (cell - previous).length_squared() >= threshold:
			out.append(cell)
			previous = cell
	return {"centers": out, "last": previous}
