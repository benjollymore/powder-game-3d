extends SceneTree
## A file shortcut issued while the unsaved-build guard has queued its Save must
## not replace that queued request, and the guard must never wait forever in
## "saving" without a dialog that can resolve it. Dialog windows are emulated by
## calling the same panel methods their signals call, so this runs headless.
const ArchivePanelScript := preload("res://scripts/editor/archive_panel.gd")
const GuardScript := preload("res://scripts/editor/document_guard.gd")

class FakeSim extends Node3D:
	var edit_epoch := 1
	var edit_revision := 1
	var bytes := PackedByteArray()
	func request_readback(callback: Callable) -> void:
		callback.call_deferred(bytes)

class FakeEditor extends Node3D:
	var document := preload("res://scripts/editor/authored_document.gd").new()
	var document_guard: Node
	var archive_panel: Node
	var sim := FakeSim.new()
	var capturing := false
	var painting := false
	var testing := false
	var pending_authored = null
	var build_snapshot := PackedByteArray()
	func _release_shortcuts() -> void: pass
	func cancel_pending_paint() -> void: pass
	func _end_stroke() -> void: painting = false
	func _reset_gesture() -> void: pass
	func _stop_navigation() -> void: pass
	func replace_authored(_bytes: PackedByteArray) -> bool: return true

var checks := 0
var failures := 0
func _initialize() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func run() -> void:
	var path := "user://review-guard-%s.p3d" % Time.get_ticks_usec()
	var editor := FakeEditor.new()
	root.add_child(editor)
	editor.add_child(editor.sim)
	var column := VBoxContainer.new()
	root.add_child(column)
	var panel: Node = ArchivePanelScript.new()
	editor.add_child(panel)
	panel.bind_editor(editor, column)
	editor.archive_panel = panel
	var guard: Node = GuardScript.new()
	editor.add_child(guard)
	guard.bind_editor(editor)
	editor.document_guard = guard
	var authored := PackedByteArray()
	authored.resize(VoxelCodec.GRID * VoxelCodec.GRID * VoxelCodec.GRID * 4)
	authored[0] = 1
	editor.sim.bytes = authored
	editor.document.changed({}) # dirty, untitled
	var stale_open := 0
	var continued := 0
	# Same shape as archive_panel._process's guarded Open: continuation plus after-save re-open.
	guard.request("open", func(): continued += 1, func(): stale_open += 1)
	await process_frame
	check(guard.state == "prompt", "dirty untitled Open reaches the Save/Discard/Cancel prompt")
	guard._save_first() # user chose "Save build": untitled, so the guard queues the Save As chooser
	check(guard.state == "saving" and panel.queued_dialog == "save", "guard queues Save As and waits in 'saving'")
	# Scene input is enabled again here (_end_modal ran), so Cmd/Ctrl+O reaches
	# interaction_lab._route_file_shortcut, which calls exactly this:
	panel._queue_dialog("open")
	check(panel.queued_dialog == "save", "a file shortcut does not replace the guard's queued Save (actual: %s)" % panel.queued_dialog)
	check(not panel.message.text.is_empty(), "the rejected request shows visible feedback: '%s'" % panel.message.text)
	panel.message.text = ""
	panel._queue_dialog("save")
	check(panel.queued_dialog == "save" and not panel.message.text.is_empty(), "a repeated Save request while one is queued is rejected with feedback, not duplicated")
	# Emulate panel._process opening the (now Open) chooser and the user cancelling it.
	panel.queued_dialog = ""
	panel._begin_modal()
	panel.open_dialog.canceled.emit()
	await process_frame
	check(guard.state.is_empty() and not panel.message.text.is_empty(), "guard leaves 'saving' with feedback once nothing can resolve the save (actual: '%s', message '%s')" % [guard.state, panel.message.text])
	var closed := 0
	guard.request("close", func(): closed += 1)
	await process_frame
	check(guard.state == "prompt", "window close/reset/empty requests reach the prompt again after the interrupted save")
	panel.message.text = ""
	panel._queue_dialog("open")
	check(panel.queued_dialog.is_empty() and not panel.message.text.is_empty(), "a file shortcut during the guard prompt is rejected with feedback")
	guard.cancel()
	# A later, unrelated explicit save now fires the stale Open continuation.
	panel.save_to_path(path)
	while panel.operation != "":
		await process_frame
	await process_frame
	print("after unrelated save: guard.state=%s continued=%d stale_open=%d dirty=%s msg=%s" % [guard.state, continued, stale_open, editor.document.is_dirty(), panel.message.text])
	check(stale_open == 0 and continued == 0 and closed == 0, "an unrelated later Save never runs an abandoned continuation (after-save %d, continuation %d, close %d)" % [stale_open, continued, closed])
	panel.operation = "save"
	panel.message.text = ""
	panel._queue_dialog("save_current")
	check(panel.queued_dialog.is_empty() and not panel.message.text.is_empty(), "a Save shortcut during a running file operation is rejected with feedback")
	panel.operation = ""
	DirAccess.remove_absolute(path)
	print("Guard queue: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
