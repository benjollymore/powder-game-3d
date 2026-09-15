extends SceneTree
class Files extends "res://scripts/editor/archive_panel.gd":
	var saves: Array[String] = []
	func save_to_path(path: String) -> void: saves.append(path)
var editor: Node3D
var files: Node
var checks := 0
var failures := 0
func _initialize() -> void: call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
func key(code: int, down: bool, command := "meta", shift := false, alt := false, echo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = down
	event.ctrl_pressed = command == "ctrl"
	event.meta_pressed = command == "meta"
	event.shift_pressed = shift
	event.alt_pressed = alt
	event.echo = echo
	Input.parse_input_event(event)
func press(code: int, command := "meta", shift := false, alt := false) -> void:
	key(code, true, command, shift, alt)
	key(code, false, command, shift, alt)
func run() -> void:
	root.size = Vector2i(1280, 800)
	root.get_node("TimeController").set_process_unhandled_input(false)
	Input.use_accumulated_input = false
	editor = load("res://tests/milestone/file_shortcuts_lab.gd").new()
	root.add_child(editor)
	files = Files.new()
	editor.add_child(files)
	files.bind_editor(editor, editor.tools_column)
	editor.archive_panel = files
	await process_frame
	editor.document.path = "/tmp/named.p3d"
	editor.play_button.grab_focus()
	key(KEY_S, true, "ctrl")
	key(KEY_S, true, "ctrl", false, false, true)
	key(KEY_S, true, "ctrl", false, false, true)
	key(KEY_S, false, "") # Command can be released before the physical key.
	check(files.queued_dialog == "save_current" and editor._file_keys_owned.is_empty() and editor.run_requests == 0, "Ctrl+S claims both edges from focused GUI and suppresses repeats without activating it")
	await process_frame
	check(files.saves == ["/tmp/named.p3d"] and not files._modal, "named Save uses existing path once without opening a chooser")
	press(KEY_S, "meta", true)
	check(files.queued_dialog == "save", "Cmd+Shift+S chooses Save As even for a named construction")
	files.queued_dialog = ""
	editor.document.path = ""
	press(KEY_S)
	check(files.queued_dialog == "save", "Cmd+S on an untitled build asks for a path")
	files.queued_dialog = ""
	editor.document.changed({})
	press(KEY_O, "ctrl")
	check(files.queued_dialog == "open" and editor.document.is_dirty(), "Ctrl+O requests normal Open without clearing dirty state")
	files.queued_dialog = ""
	editor.document.path = "/tmp/named.p3d"
	var text: LineEdit = editor.radius_input.get_line_edit()
	text.grab_focus()
	var before: String = text.text
	press(KEY_S)
	await process_frame
	check(files.saves.size() == 2 and text.text == before and not editor.erase, "file Save works from numeric text focus without changing text or tools")
	press(KEY_Z, "ctrl")
	press(KEY_Z, "meta", true)
	check(editor.undo_requests == 0 and editor.redo_requests == 0, "focused numeric text retains its own Undo and Redo")
	editor.play_button.grab_focus()
	var radius: int = editor.radius
	var material: int = editor.element
	var position: Vector3 = editor.camera.position
	var unchanged := true
	for command in ["ctrl", "meta", "alt", "shift"]:
		editor.painting = true
		for code in [KEY_P, KEY_N, KEY_X, KEY_B, KEY_1, KEY_BRACKETLEFT, KEY_F, KEY_V, KEY_K]:
			press(code, command, command == "shift", command == "alt")
		unchanged = unchanged and editor.painting and editor.pauses == 0 and editor.steps == 0 and not editor.erase and not editor.selecting and editor.radius == radius and editor.element == material and editor.camera.position == position
	check(unchanged, "unrelated modified commands neither trigger plain sandbox actions nor end a held stroke")
	press(KEY_Z, "ctrl", false, true)
	press(KEY_O, "meta", true)
	press(KEY_S, "ctrl", false, true)
	check(editor.undo_requests == 0 and files.queued_dialog.is_empty() and editor.painting, "Alt+command and unassigned Shift+Open combinations do not leak into editor actions")
	press(KEY_P, "")
	press(KEY_N, "")
	press(KEY_X, "")
	check(editor.pauses == 1 and editor.steps == 1 and editor.erase and not editor.painting, "unmodified pause, step and erase still work normally")
	editor.capturing = true
	press(KEY_S)
	await process_frame
	check(files.queued_dialog == "save_current" and files.saves.size() == 2, "named shortcut waits for outstanding authored history capture")
	editor.capturing = false
	await process_frame
	check(files.saves.size() == 3 and files.queued_dialog.is_empty(), "named shortcut saves after the outstanding edit finishes")
	key(KEY_S, true)
	files._begin_modal()
	files.queued_dialog = ""
	press(KEY_S)
	press(KEY_O)
	check(files.queued_dialog.is_empty() and editor._file_keys_owned.is_empty(), "modal/native ownership blocks file shortcuts and clears pre-modal held-key ownership")
	files._end_modal()
	press(KEY_S)
	check(files.queued_dialog == "save_current", "file shortcuts resume after modal ownership returns")
	files.queued_dialog = ""
	key(KEY_S, true)
	editor._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(editor._file_keys_owned.is_empty(), "focus loss terminates shortcut key ownership")
	files.queued_dialog = ""
	editor.queue_free()
	await process_frame
	print("File shortcuts CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
