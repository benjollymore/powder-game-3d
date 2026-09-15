extends SceneTree
const Document := preload("res://scripts/editor/authored_document.gd")
const Guard := preload("res://scripts/editor/document_guard.gd")
class Sim extends Node3D:
	var edit_epoch := 1
class Files extends Node:
	signal save_finished(ok: bool, token: int, generation: int)
	signal save_canceled
	var _modal := false
	var queued_dialog := ""
	var operation := ""
	var message := Label.new()
	var requested_path := ""
	func _begin_modal() -> void: _modal = true
	func _end_modal() -> void: _modal = false
	func save_to_path(path: String) -> void: requested_path = path
	func _queue_dialog(which: String, _from_guard := false) -> void: queued_dialog = which
class Editor extends Node3D:
	var document := Document.new()
	var sim := Sim.new()
	var archive_panel := Files.new()
	var capturing := false
	var painting := false
	var pending_authored: RefCounted
	func cancel_pending_paint() -> void: pending_authored = null
	func _end_stroke() -> void: painting = false
var checks := 0
var failures := 0
var applied := 0
func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s: %s" % ["ok" if ok else "FAIL", label])
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var editor := Editor.new()
	root.add_child(editor)
	editor.add_child(editor.sim)
	editor.add_child(editor.archive_panel)
	editor.archive_panel.add_child(editor.archive_panel.message)
	var document = editor.document
	document.reset()
	var base: int = document.current
	check(not document.is_dirty() and document.label() == "Untitled", "fresh template starts clean without falsely claiming a saved file")
	var edit := {}
	document.changed(edit)
	check(document.is_dirty(), "accepted authored edit creates an unsaved checkpoint")
	document.saved_capture(document.current, document.generation, "/tmp/build.p3d")
	var saved: int = document.current
	check(not document.is_dirty() and document.label() == "build.p3d · Saved", "only successful exact capture marks the checkpoint saved")
	var inverse := {}
	document.reversed(edit, inverse, false)
	check(document.current == base and document.is_dirty(), "Undo away from saved state is dirty")
	document.reversed(inverse, {}, true)
	check(document.current == saved and not document.is_dirty(), "Redo back to saved state is clean")
	var next := {}
	document.changed(next)
	document.reversed(next, {}, false)
	check(document.current == saved and not document.is_dirty(), "Undo a newer edit returns to saved identity without hashing a world")
	var generation: int = document.generation
	document.reset()
	check(not document.saved_capture(saved, generation, "/tmp/old.p3d") and document.path.is_empty(), "late save cannot rename or mark a replaced document saved")
	var previous_quit := auto_accept_quit
	var guard := Guard.new()
	editor.add_child(guard)
	guard.bind_editor(editor)
	check(not auto_accept_quit, "document guard owns normal window-close policy")
	guard.request("reset", func(): applied += 1)
	check(applied == 1 and guard.state.is_empty(), "clean replacement proceeds without a confirmation")
	document.changed({})
	guard.request("empty", func(): applied += 1)
	check(guard.state == "prompt" and applied == 1 and editor.archive_panel._modal, "dirty replacement waits for an explicit choice with modal input ownership")
	guard.cancel()
	check(applied == 1 and document.is_dirty() and not editor.archive_panel._modal, "Cancel preserves authored work and releases modal ownership")
	guard.request("reset", func(): applied += 1)
	guard._save_first()
	check(guard.state == "saving" and editor.archive_panel.queued_dialog == "save", "untitled Save choice opens a file selection before replacing")
	editor.archive_panel.queued_dialog = ""
	editor.archive_panel.save_canceled.emit()
	check(guard.state.is_empty() and applied == 1 and document.is_dirty(), "canceling Save cancels the destructive continuation")
	document.path = "/tmp/build.p3d"
	guard.request("reset", func(): applied += 1)
	guard._save_first()
	editor.archive_panel.save_finished.emit(false, document.current, document.generation)
	check(applied == 1 and guard.state.is_empty() and document.is_dirty(), "failed Save cannot authorize the pending reset")
	guard.request("reset", func(): applied += 1)
	guard._save_first()
	var captured: int = document.current
	document.changed({})
	document.saved_capture(captured, document.generation, document.path)
	editor.archive_panel.save_finished.emit(true, captured, document.generation)
	check(applied == 1 and guard.state.is_empty() and document.is_dirty(), "successful earlier Save cannot discard a newer authored checkpoint")
	guard.request("reset", func(): applied += 1)
	guard._save_first()
	captured = document.current
	document.saved_capture(captured, document.generation, document.path)
	editor.capturing = true
	editor.archive_panel.save_finished.emit(true, captured, document.generation)
	check(applied == 1 and guard.state.is_empty(), "an unfinished newer stroke blocks discard even before it assigns its checkpoint")
	editor.capturing = false
	document.changed({})
	guard.request("reset", func(): applied += 1)
	guard._save_first()
	captured = document.current
	document.saved_capture(captured, document.generation, document.path)
	editor.archive_panel.save_finished.emit(true, captured, document.generation)
	check(applied == 2 and guard.state.is_empty(), "successful unchanged Save authorizes exactly one continuation")
	document.changed({})
	guard.request("empty", func(): applied += 1)
	document.changed({})
	guard._discard()
	check(applied == 2 and guard.state.is_empty(), "discard approval is invalidated when its displayed checkpoint changes")
	guard.request("open", func(): applied += 1)
	guard._discard()
	check(applied == 3 and guard.state.is_empty(), "explicit Discard applies only the approved current document")
	document.changed({})
	guard.request("open", func(): applied += 1, func(): applied += 10)
	guard._save_first()
	document.saved_capture(document.current, document.generation, document.path)
	editor.archive_panel.save_finished.emit(true, document.current, document.generation)
	check(applied == 13, "Open after Save uses fresh-file continuation rather than stale validated bytes")
	guard.free()
	check(auto_accept_quit == previous_quit, "guard teardown restores the previous window-close policy")
	editor.free()
	print("Authored document CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
