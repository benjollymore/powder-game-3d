extends RefCounted
## One retained-byte budget for both directions of authored history.
const LIMIT := 128 * 1024 * 1024
static func trim(undo: Array, redo: Array, undo_bytes: int, redo_bytes: int, limit: int = LIMIT) -> Vector2i:
	while undo_bytes + redo_bytes > limit:
		if not undo.is_empty():
			undo_bytes -= undo.pop_front().bytes # oldest past edit
		elif not redo.is_empty():
			redo_bytes -= redo.pop_front().bytes # farthest future edit
		else:
			break
	return Vector2i(undo_bytes, redo_bytes)
