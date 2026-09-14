extends SceneTree
const ArchivePanelScript := preload("res://scripts/editor/archive_panel.gd")
const Archive := preload("res://scripts/editor/world_archive.gd")

class FakeSim extends Node3D:
	var edit_epoch := 1
	var edit_revision := 1
	var bytes := PackedByteArray()
	func request_readback(callback: Callable) -> void:
		callback.call_deferred(bytes)

class FakeEditor extends Node3D:
	var sim := FakeSim.new()
	var capturing := false
	var painting := false
	var testing := false
	var build_snapshot := PackedByteArray()
	var replacements := 0
	func _input(_event: InputEvent) -> void:
		pass
	func _unhandled_input(_event: InputEvent) -> void:
		pass
	func _end_stroke() -> void:
		painting = false
	func _reset_gesture() -> void:
		pass
	func _stop_navigation() -> void:
		pass
	func replace_authored(bytes: PackedByteArray) -> bool:
		if capturing or painting:
			return false
		sim.bytes = bytes
		sim.edit_epoch += 1
		testing = false
		replacements += 1
		return true

var panel: Node
var editor: FakeEditor
var checks := 0
var failures := 0

func _initialize() -> void:
	create_timer(20.0).timeout.connect(func(): quit(1))
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func wait_for_file() -> void:
	while panel.operation != "":
		await process_frame

func run() -> void:
	var path := "user://archive-panel-%s.p3d" % Time.get_ticks_usec()
	editor = FakeEditor.new()
	root.add_child(editor)
	editor.add_child(editor.sim)
	var column := VBoxContainer.new()
	root.add_child(column)
	panel = ArchivePanelScript.new()
	editor.add_child(panel)
	panel.bind_editor(editor, column)
	var authored := PackedByteArray()
	authored.resize(VoxelCodec.GRID * VoxelCodec.GRID * VoxelCodec.GRID * 4)
	authored.fill(0)
	authored[0] = 1
	editor.sim.bytes = authored
	panel.save_to_path(path)
	await wait_for_file()
	check(Archive.load_authored(path, VoxelCodec.GRID).bytes == authored, "Build save uses the capture callback's authored bytes")
	var live := authored.duplicate()
	live[0] = 3
	editor.build_snapshot = authored
	editor.sim.bytes = live
	editor.testing = true
	panel.save_to_path(path)
	await wait_for_file()
	check(Archive.load_authored(path, VoxelCodec.GRID).bytes == authored, "Save during Test preserves construction rather than live destruction")
	panel.open_path(path)
	editor.sim.edit_revision += 1
	await wait_for_file()
	check(editor.replacements == 0 and editor.sim.bytes == live, "late load cannot overwrite a newer edit")
	panel.open_path(path)
	await wait_for_file()
	check(editor.replacements == 1 and editor.sim.bytes == authored and not editor.testing, "valid load applies the authored replacement")
	panel.open_path(path + ".missing")
	await wait_for_file()
	check(editor.replacements == 1, "failed file load leaves world intact")
	editor.set_process_unhandled_input(false)
	panel._begin_modal()
	check(not editor.is_processing_input() and not editor.is_processing_unhandled_input(), "file dialog owns input ahead of scene gestures")
	panel._end_modal()
	check(editor.is_processing_input() and not editor.is_processing_unhandled_input(), "closing dialog restores prior input settings")
	DirAccess.remove_absolute(path)
	editor.queue_free()
	column.queue_free()
	await process_frame
	print("Archive panel: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
