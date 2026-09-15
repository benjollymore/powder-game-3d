extends "res://tests/milestone/document_protection_gpu.gd"
## Parsed shortcut events plus real GPU/history/file operations. Native chooser
## selections are supplied through FileDialog signals, not physical OS input.
var successful_saves := 0
func command(code: int, meta := true, shift := false, echo := false, down := true) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.meta_pressed = meta
	event.ctrl_pressed = not meta
	event.shift_pressed = shift
	event.echo = echo
	event.pressed = down
	Input.parse_input_event(event)
func shortcut(code: int, meta := true, shift := false) -> void:
	command(code, meta, shift)
	command(code, meta, shift, false, false)
func finish_file_selection(path: String, opening := false) -> void:
	panel.queued_dialog = "" # Supply the native response before launching its OS UI.
	panel._begin_modal()
	if opening: panel.open_dialog.file_selected.emit(path)
	else: panel.save_dialog.file_selected.emit(path)
func saved() -> void:
	while panel.queued_dialog == "save_current" or panel.operation != "" or editor.capturing:
		await process_frame
	await frames(2)
func run() -> void:
	output_dir = "/tmp/editor-file-shortcuts"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): output_dir = arg.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(output_dir)
	original_cursor = DisplayServer.mouse_get_position()
	original_accumulation = Input.use_accumulated_input
	input_configured = true
	Input.use_accumulated_input = false
	root.size = Vector2i(1280, 800)
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	clock = root.get_node("TimeController")
	guard = editor.document_guard
	panel = editor.archive_panel
	panel.save_finished.connect(func(ok, _token, _generation):
		if ok: successful_saves += 1)
	await frames(12)
	baseline = await read()
	var n := VoxelCodec.GRID
	first = Vector3i(n * 7 / 8, n * 7 / 8, n / 2)
	second = first + Vector3i(0, -5, 0)
	third = first + Vector3i(0, -10, 0)
	editor.radius_input.value = 0
	var file := output_dir.path_join("named.p3d")
	var alternative := output_dir.path_join("save-as.p3d")
	var authored := await draw(first)
	shortcut(KEY_S)
	check(panel.queued_dialog == "save" and editor.document.is_dirty(), "parsed Cmd+S on dirty Untitled requests a path without discarding work")
	finish_file_selection(file)
	await saved()
	check(WorldArchive.load_authored(file, n).bytes == authored and not editor.document.is_dirty() and editor.document.path == file, "untitled shortcut writes exact authored bytes and establishes named clean state")
	authored = await draw(second)
	editor.play_button.grab_focus()
	command(KEY_S, false)
	command(KEY_S, false, false, true)
	command(KEY_S, false, false, true)
	command(KEY_S, false, false, false, false)
	await saved()
	check(successful_saves == 2 and not editor.testing and not panel._modal and WorldArchive.load_authored(file, n).bytes == authored, "focused GUI Ctrl+S overwrites the named file exactly once without a chooser or Run activation")
	move_to(point(third))
	mouse(true)
	mouse(false)
	shortcut(KEY_S)
	check(editor.capturing and panel.queued_dialog == "save_current", "Save shortcut issued immediately after release waits for real asynchronous history")
	await saved()
	authored = await read()
	check(id_at(authored, third) == Elements.Id.SAND and WorldArchive.load_authored(file, n).bytes == authored and not editor.document.is_dirty(), "queued named Save includes the just-finished stroke and its exact checkpoint")
	var history_size: int = editor.undo_history.size()
	var text: LineEdit = editor.radius_input.get_line_edit()
	text.grab_focus()
	shortcut(KEY_Z)
	shortcut(KEY_Z, false)
	shortcut(KEY_Z, true, true)
	check(editor.undo_history.size() == history_size and not editor.capturing and await read() == authored, "empty numeric text history cannot leak Cmd/Ctrl Undo or Redo into authored history")
	shortcut(KEY_S, false, true)
	check(panel.queued_dialog == "save", "Ctrl+Shift+S from numeric focus always requests Save As")
	finish_file_selection(alternative)
	await saved()
	check(editor.document.path == alternative and WorldArchive.load_authored(alternative, n).bytes == authored and WorldArchive.load_authored(file, n).bytes == authored, "Save As shortcut changes the active filename while preserving the original file")
	await click(editor.play_button)
	await settled()
	await frames(4)
	shortcut(KEY_S)
	await saved()
	check(editor.testing and not editor.document.is_dirty() and WorldArchive.load_authored(alternative, n).bytes == authored, "Cmd+S during running Test saves the authored construction rather than live material")
	await click(editor.pause_button)
	await read()
	var tick_before: int = sim.tick
	var erase_before: bool = editor.erase
	for meta in [true, false]:
		for code in [KEY_P, KEY_N, KEY_X, KEY_B]: shortcut(code, meta)
	await frames(3)
	check(clock.is_frozen() and sim.tick == tick_before and editor.erase == erase_before and not editor.selecting, "modified P/N/X/B cannot unpause, step, erase or select in the real Test loop")
	move_to(point(first + Vector3i(0, -20, 0)))
	mouse(true)
	shortcut(KEY_K)
	check(editor.painting and editor.live_emitter_signature != 0, "unrelated command shortcut does not terminate a live held source")
	mouse(false)
	await click(editor.play_button)
	await settled()
	check(await read() == authored and not editor.document.is_dirty(), "Return after shortcut tests preserves exact authored checkpoint")
	var dirty := await draw(first + Vector3i(0, -15, 0))
	shortcut(KEY_O)
	check(panel.queued_dialog == "open", "Cmd+O enters the existing Open chooser workflow")
	finish_file_selection(file, true)
	await file_idle()
	check(guard.state == "prompt" and await read() == dirty, "shortcut Open cannot bypass dirty-build discard protection")
	await choice_key(KEY_ESCAPE)
	check(guard.state.is_empty() and await read() == dirty and editor.document.is_dirty(), "Cancel after shortcut Open preserves the complete dirty construction")
	shortcut(KEY_O, false)
	finish_file_selection(file, true)
	await file_idle()
	await choice(guard.discard_button)
	check(await read() == authored and editor.document.path == file and not editor.document.is_dirty(), "Ctrl+O plus explicit Discard opens the intended file and restores clean state")
	panel._begin_modal()
	var saves_before: int = successful_saves
	shortcut(KEY_S)
	shortcut(KEY_O)
	await frames(2)
	check(panel.queued_dialog.is_empty() and panel.operation.is_empty() and successful_saves == saves_before, "native/modal ownership prevents global file shortcuts from launching another operation")
	panel._end_modal()
	await click(panel.save_button)
	await saved()
	check(successful_saves == saves_before + 1 and not panel._modal, "visible named Save button follows the same no-chooser path as Cmd/Ctrl+S")
	_restore_input()
	await frames(2)
	print("File shortcuts GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
