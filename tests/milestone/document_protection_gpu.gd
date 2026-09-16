extends "res://tests/milestone/editor_workflow_gpu.gd"
## Parsed canvas/UI input and real archive/history callbacks. Native file picker
## results/cancellation are injected at their signals; no OS shutdown is invoked.
var baseline: PackedByteArray
var guard: Node
var panel: Node
var first: Vector3i
var second: Vector3i
var third: Vector3i
func file_idle() -> void:
	while panel.operation != "": await process_frame
func draw(cell: Vector3i) -> PackedByteArray:
	move_to(point(cell))
	await frames(1)
	mouse(true)
	mouse(false)
	await settled()
	return await read()
func action_button(prefix: String) -> void:
	editor._set_advanced(true)
	await frames(2)
	var button := find_button(prefix)
	editor.tools_scroll.ensure_control_visible(button)
	await frames(2)
	await click(button)
	await settled()
func choice_key(code: int) -> void:
	var event := InputEventKey.new()
	event.window_id = guard.dialog.get_window_id()
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await frames(2)
func choice(button: Button) -> void:
	# Embedded dialogs share root input coordinates. Native subwindows own an
	# explicit window ID; this harness records which production route is used.
	var position: Vector2 = button.get_global_rect().get_center()
	if guard.dialog.is_embedded():
		position += Vector2(guard.dialog.position)
		await click_at(position)
	else:
		var motion := InputEventMouseMotion.new()
		motion.window_id = guard.dialog.get_window_id()
		motion.position = position
		Input.parse_input_event(motion)
		for down in [true, false]:
			var event := InputEventMouseButton.new()
			event.window_id = motion.window_id
			event.position = position
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = down
			Input.parse_input_event(event)
			await frames(1)
	await frames(2)
func click_at(position: Vector2) -> void:
	move_to(position)
	await frames(1)
	mouse(true)
	await frames(1)
	mouse(false)
	await frames(2)
func prepare_dirty() -> PackedByteArray:
	guard.cancel()
	editor.replace_authored(baseline)
	editor.radius_input.value = 0
	editor._choose_material(Elements.Id.SAND)
	editor._set_advanced(false)
	editor.tools_scroll.scroll_vertical = 0
	await frames(2)
	return await draw(first)
func run() -> void:
	output_dir = "/tmp/editor-document-protection"
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
	await frames(12)
	baseline = await read()
	var n := VoxelCodec.GRID
	first = Vector3i(n * 7 / 8, n * 7 / 8, n / 2)
	second = first + Vector3i(0, -5, 0)
	third = first + Vector3i(0, -10, 0)
	editor.radius_input.value = 0
	var file := output_dir.path_join("baseline.p3d")
	panel.save_to_path(file)
	await file_idle()
	check(not editor.document.is_dirty() and editor.document.path == file, "successful baseline Save establishes an exact clean checkpoint and filename")
	var wall := Vector3i(n / 2, n / 6, n / 2)
	check(id_at(baseline, wall) == Elements.Id.WALL, "no-op fixture targets an actual container wall")
	await draw(wall)
	check(await read() == baseline and not editor.document.is_dirty() and editor.undo_history.is_empty(), "ONLY_AIR paint over a wall remains clean and creates no false document checkpoint")
	var authored := await draw(first)
	check(authored != baseline and editor.document.is_dirty(), "parsed authored paint marks current construction unsaved")
	panel.save_to_path(file)
	await file_idle()
	check(not editor.document.is_dirty() and WorldArchive.load_authored(file, n).bytes == authored, "successful Save stores exact painted bytes and clears dirty state")
	await click(editor.undo_button)
	await settled()
	check(editor.document.is_dirty() and await read() == baseline, "Undo away from the saved file is visibly unsaved")
	await click(editor.redo_button)
	await settled()
	check(not editor.document.is_dirty() and await read() == authored, "Redo back to the saved file restores clean identity and exact bytes")
	await draw(second)
	await click(editor.undo_button)
	await settled()
	check(not editor.document.is_dirty() and await read() == authored, "Undo a newer stroke returns to the saved checkpoint without prompting")
	await click(editor.play_button)
	await settled()
	await frames(5)
	check(editor.testing and not editor.document.is_dirty() and guard.state.is_empty(), "running physics does not dirty the authored build or prompt")
	panel.save_to_path(file)
	await file_idle()
	check(WorldArchive.load_authored(file, n).bytes == authored and not editor.document.is_dirty(), "Save during Test stores the authored checkpoint, independent of live evolution")
	await click(editor.play_button)
	await settled()
	check(await read() == authored and not editor.document.is_dirty(), "Return restores exact saved construction and remains clean")
	authored = await draw(second)
	await action_button("Reset container")
	print("DOCUMENT_DIALOG embedded=", guard.dialog.is_embedded(), " state=", guard.state, " dirty=", editor.document.is_dirty())
	check(guard.state == "prompt" and guard.dialog.visible and await read() == authored, "actual Reset button preserves dirty GPU state and displays Save/Discard/Cancel")
	await choice_key(KEY_ESCAPE)
	check(guard.state.is_empty() and editor.document.is_dirty() and await read() == authored, "parsed Escape cancels Reset and preserves every authored byte")
	await action_button("Empty build")
	await choice(guard.dialog.get_cancel_button())
	check(guard.state.is_empty() and await read() == authored, "parsed Cancel button preserves dirty work after Empty")
	await action_button("Empty build")
	await choice(guard.discard_button)
	await settled()
	var empty := PackedByteArray()
	empty.resize(baseline.size())
	check(await read() == empty and not editor.document.is_dirty() and editor.undo_history.is_empty(), "explicit parsed Discard permits Empty and resets document/history together")
	# Open validates first; canceling the actual document choice preserves work.
	authored = await prepare_dirty()
	panel.open_path(file + ".missing")
	await file_idle()
	check(guard.state.is_empty() and await read() == authored, "invalid Open reports failure without a discard prompt or authored mutation")
	panel.open_path(file)
	await file_idle()
	check(guard.state == "prompt" and await read() == authored, "valid dirty Open waits for discard permission after loading")
	await choice_key(KEY_ESCAPE)
	check(guard.state.is_empty() and await read() == authored, "canceling dirty Open preserves exact construction and history")
	panel.open_path(file)
	await file_idle()
	await choice(guard.discard_button)
	check(not editor.document.is_dirty() and editor.document.path == file and await read() == WorldArchive.load_authored(file, n).bytes, "explicit Open Discard applies the validated file and clean filename")
	# Reopening the same path and choosing Save must reload its new contents.
	authored = await draw(second)
	panel.open_path(file)
	await file_idle()
	await choice(guard.dialog.get_ok_button())
	await file_idle()
	check(await read() == authored and WorldArchive.load_authored(file, n).bytes == authored and not editor.document.is_dirty(), "Open same file then Save reloads the new saved bytes instead of applying a stale cached file")
	# Save-and-replace uses the actual threaded write before destructive action.
	authored = await draw(third)
	await action_button("Reset container")
	await choice(guard.dialog.get_ok_button())
	await file_idle()
	await settled()
	check(guard.state.is_empty() and await read() == baseline and WorldArchive.load_authored(file, n).bytes == authored, "Save choice writes exact dirty bytes before resetting the container")
	# Native cancellation is injected at FileDialog's cancellation signal before
	# its queued OS popup opens. This explicitly does not test native UI input.
	authored = await prepare_dirty()
	editor.new_empty_build()
	guard._save_first()
	check(panel.queued_dialog == "save" and guard.state == "saving", "untitled destructive Save requests a native file selection")
	panel.queued_dialog = ""
	panel.save_dialog.canceled.emit()
	check(guard.state.is_empty() and await read() == authored and editor.document.is_dirty(), "native picker cancellation signal preserves unsaved construction")
	# Inject an untitled Save As result while Open is pending. The original
	# requested Open path must survive ArchivePanel.selected_path changing.
	var open_target := output_dir.path_join("other-baseline.p3d")
	var save_as := output_dir.path_join("new-save-as.p3d")
	WorldArchive.save_authored(open_target, baseline, n)
	panel.open_path(open_target)
	await file_idle()
	guard._save_first()
	panel.queued_dialog = ""
	panel.save_dialog.file_selected.emit(save_as)
	await file_idle()
	check(await read() == baseline and editor.document.path == open_target and WorldArchive.load_authored(save_as, n).bytes == authored,
		"Save As during dirty Open saves current work separately and still opens the originally selected file")
	# A previously valid saved folder can disappear before the next Save.
	var gone := output_dir.path_join("removed-folder")
	DirAccess.make_dir_recursive_absolute(gone)
	var unavailable := gone.path_join("build.p3d")
	panel.save_to_path(unavailable)
	await file_idle()
	authored = await draw(second)
	DirAccess.remove_absolute(unavailable)
	DirAccess.remove_absolute(gone)
	editor.new_empty_build()
	guard._save_first()
	await file_idle()
	check(guard.state.is_empty() and await read() == authored and editor.document.is_dirty() and panel.message.text.contains("Cannot write"), "real disk Save failure cannot execute the pending Empty action")
	# A newer canvas event after the save snapshot must revoke continuation.
	panel.save_to_path(file)
	await file_idle()
	await draw(third)
	editor.new_empty_build()
	guard._save_first()
	move_to(point(first + Vector3i(0, -15, 0)))
	mouse(true)
	mouse(false)
	await settled()
	await file_idle()
	check(guard.state.is_empty() and editor.document.is_dirty() and await read() != empty and panel.message.text.contains("changed"), "parsed newer paint after Save capture cancels destructive continuation")
	var current := await read()
	check(WorldArchive.load_authored(file, n).bytes != current, "saved file contains the older snapshot, never falsely claims to include the newer stroke")
	panel.open_path(file)
	move_to(point(first + Vector3i(0, -20, 0)))
	mouse(true)
	mouse(false)
	await settled()
	await file_idle()
	check(guard.state.is_empty() and panel.message.text.contains("changed") and await read() != current, "stale asynchronous Open is rejected before a discard dialog can authorize old state")
	current = await read()
	root.close_requested.emit()
	check(not auto_accept_quit and guard.state == "prompt", "normal root window-close signal is intercepted for dirty authored work")
	await choice_key(KEY_ESCAPE)
	check(guard.state.is_empty() and await read() == current and editor.is_processing_input(), "canceling window close preserves exact authored bytes and restores editor input")
	root.close_requested.emit()
	await frames(2)
	root.get_texture().get_image().save_png(output_dir.path_join("unsaved-close.png"))
	check(guard.dialog.visible and panel.document_status.text.contains("Unsaved"), "close confirmation and current unsaved filename remain visible at laptop resolution")
	# Complete the same normal-close route only after all assertions passed.
	if failures:
		_restore_input()
		print("Document protection GPU: %d checks, %d failures" % [checks, failures])
		quit(1)
		return
	guard.action_completed.connect(func(kind):
		if kind == "close":
			check(true, "explicit Discard completes the normal close route exactly once")
			_restore_input()
			print("Document protection GPU: %d checks, %d failures" % [checks, failures]))
	# Do not suspend another coroutine across quit: send this final embedded
	# dialog click synchronously and let the production close callback exit.
	var close_position: Vector2 = guard.discard_button.get_global_rect().get_center() + Vector2(guard.dialog.position)
	move_to(close_position)
	mouse(true)
	mouse(false)
