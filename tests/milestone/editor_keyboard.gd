extends SceneTree
var editor: Node3D
var checks := 0
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, label: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", label])
	if not ok:
		failures += 1
func send_key(code: int, down: bool, echo := false, ctrl := false, shift := false, meta := false) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.unicode = code if code < 128 else 0
	event.pressed = down
	event.echo = echo
	event.ctrl_pressed = ctrl
	event.shift_pressed = shift
	event.meta_pressed = meta
	Input.parse_input_event(event)
func find_button(prefix: String, node: Node) -> BaseButton:
	if node is BaseButton and node.text.begins_with(prefix):
		return node
	for child in node.get_children():
		var button := find_button(prefix, child)
		if button != null:
			return button
	return null
func run() -> void:
	root.size = Vector2i(1280, 800)
	Input.use_accumulated_input = false
	# This fixture overrides _ready; mirror the actual editor's lifetime policy.
	root.get_node("TimeController").set_process_unhandled_input(false)
	editor = load("res://tests/milestone/editor_keyboard_lab.gd").new()
	root.add_child(editor)
	await process_frame
	editor.advanced_toggle.button_pressed = true
	var reset := find_button("Reset container", editor.tools_column)
	var undo := find_button("Undo build", editor.tools_column)
	undo.disabled = false # Make the focus probe meaningful with an empty fixture.
	for button in [reset, undo]:
		button.grab_focus() # Equivalent keyboard focus after clicking/tabbing.
		send_key(KEY_SPACE, true)
		send_key(KEY_SPACE, false)
	await process_frame
	check(editor.run_requests == 2 and editor.reset_requests == 0 and editor.undo_requests == 0,
		"Space with actual Reset/Undo button focus requests Run once without activating either GUI action")
	reset.grab_focus()
	send_key(KEY_SPACE, true)
	send_key(KEY_SPACE, true, true)
	send_key(KEY_SPACE, true, true)
	send_key(KEY_SPACE, false)
	check(editor.run_requests == 3 and editor.reset_requests == 0, "held Space echoes cannot retrigger phase or focused button")
	var text: LineEdit = editor.radius_input.get_line_edit()
	text.grab_focus()
	var before: String = text.text
	send_key(KEY_SPACE, true)
	send_key(KEY_SPACE, false)
	check(editor.run_requests == 3 and text.text != before, "Space in numeric text input edits text without starting Test")
	reset.grab_focus()
	send_key(KEY_SPACE, true, false, true)
	send_key(KEY_SPACE, false, false, true)
	check(editor.run_requests == 3, "modified Space is not claimed as the editor phase shortcut")
	reset.grab_focus()
	send_key(KEY_Z, true, false, true, true)
	send_key(KEY_Z, false, false, true, true)
	send_key(KEY_Z, true, false, false, true, true)
	send_key(KEY_Z, false, false, false, true, true)
	check(editor.redo_requests == 2 and editor.undo_requests == 0, "Ctrl/Cmd Shift Z requests Redo without Undo or focused button activation")
	text.grab_focus()
	send_key(KEY_Z, true, false, true, true)
	send_key(KEY_Z, false, false, true, true)
	check(editor.redo_requests == 2, "numeric text retains its own redo shortcut")
	# Modal ownership is tested with the production archive panel, without
	# opening a native OS dialog in this headless regression.
	var panel = load("res://scripts/editor/archive_panel.gd").new()
	editor.add_child(panel)
	panel.bind_editor(editor, editor.tools_column)
	editor.archive_panel = panel
	panel._begin_modal()
	send_key(KEY_SPACE, true)
	send_key(KEY_SPACE, false)
	check(editor.run_requests == 3, "modal dialog suspension prevents Space from changing editor phase")
	panel._end_modal()
	reset.grab_focus()
	var resets_before_enter: int = editor.reset_requests
	send_key(KEY_ENTER, true)
	send_key(KEY_ENTER, false)
	check(editor.reset_requests == resets_before_enter + 1, "Enter still activates a focused GUI action for keyboard access")
	editor.queue_free()
	await process_frame
	print("Editor keyboard: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
