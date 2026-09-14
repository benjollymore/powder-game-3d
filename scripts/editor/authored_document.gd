extends RefCounted
## Logical authored checkpoints. Runtime ticks and viewport settings never change
## these IDs. History records carry both ends so Undo can return to a saved ID.
var current := 0
var saved := 0
var generation := 0
var path := ""
var _next := 0

func reset() -> void:
	generation += 1
	_next += 1
	current = _next
	saved = current
	path = ""

func is_dirty() -> bool:
	return current != saved

func changed(record: Dictionary) -> void:
	record.document_before = current
	_next += 1
	current = _next
	record.document_after = current

func reversed(original: Dictionary, inverse: Dictionary, redo: bool) -> void:
	if not original.has("document_before") or not original.has("document_after"):
		# Unknown/legacy history is conservatively unsaved, never falsely clean.
		changed(inverse)
		return
	inverse.document_before = original.document_before
	inverse.document_after = original.document_after
	current = original.document_after if redo else original.document_before

func saved_capture(token: int, document_generation: int, file_path: String) -> bool:
	if document_generation != generation:
		return false
	saved = token
	path = file_path
	return true

func label() -> String:
	var name := "Untitled" if path.is_empty() else path.get_file()
	return name + (" · Unsaved changes" if is_dirty() else " · Saved" if not path.is_empty() else "")
