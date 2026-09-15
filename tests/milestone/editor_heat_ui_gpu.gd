extends "res://tests/milestone/document_protection_gpu.gd"
## Examples through the guard, Keep result as one undoable revision, the speed
## slider and the number-key row, with real GPU history and parsed input.
func key(code: int) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		Input.parse_input_event(event)
func kept() -> void:
	while editor.keeping or editor.capturing or not editor._queued_editor_action.is_empty():
		await process_frame
	await frames(2)
func run() -> void:
	output_dir = "/tmp/editor-heat-ui"
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
	# Examples: clean build loads immediately as an untitled clean world.
	editor.load_example("Dam break")
	await frames(3)
	await settled()
	await frames(2)
	var dam: PackedByteArray = await read()
	check(dam == Scenarios.build("Dam break") and not editor.document.is_dirty() and editor.document.path.is_empty() and guard.state.is_empty(),
		"Examples loads the exact scenario bytes as a clean untitled build")
	check(editor.undo_history.is_empty() and editor.redo_history.is_empty(), "loading an example starts fresh history, like Open")
	# Number keys follow the first row.
	editor.play_button.grab_focus()
	key(KEY_3)
	check(editor.element == Elements.Id.WALL, "key 3 selects Wall, the third material of the first row")
	key(KEY_1)
	check(editor.element == Elements.Id.SAND, "key 1 selects Sand")
	key(KEY_2)
	check(editor.element == Elements.Id.WATER, "key 2 selects Water")
	# Examples on a dirty build are guarded; Cancel preserves every byte.
	editor.radius_input.value = 0
	key(KEY_1)
	first = Vector3i(n * 7 / 8, n * 7 / 8, n / 2)
	var dirty := await draw(first)
	check(dirty != dam and editor.document.is_dirty(), "a stroke on the example makes it unsaved")
	editor.load_example("Demo")
	await frames(3)
	check(guard.state == "prompt" and await read() == dirty, "Examples on unsaved work prompts before replacing anything")
	await choice_key(KEY_ESCAPE)
	check(guard.state.is_empty() and await read() == dirty and editor.document.is_dirty(), "Cancel keeps the unsaved example edits")
	# Speed slider drives the clock when Test starts.
	editor.speed_slider.value = 1
	check(is_equal_approx(editor.speed_scale, 2.0), "slider step 1 means 2x")
	var authored: PackedByteArray = dirty
	await click(editor.play_button)
	await settled()
	await frames(2)
	check(editor.testing and is_equal_approx(clock.time_scale, 2.0), "Run applies the chosen speed")
	editor.speed_slider.value = 0
	sim.request_ticks(30)
	await read()
	await frames(2)
	var undo_before: int = editor.undo_history.size()
	await click(editor.keep_button)
	await kept()
	var kept_bytes: PackedByteArray = await read()
	check(not editor.testing and not editor.keeping and kept_bytes != authored and clock.paused, "Keep leaves Test with the evolved experiment as the build")
	check(editor.undo_history.size() == undo_before + 1 and editor.document.is_dirty() and editor.edit_message.begins_with("Kept"), "Keep records one undoable edit and marks the build unsaved")
	check(editor.play_button.text.begins_with("Run") and not editor.test_time_controls.visible, "editor returns to Build controls after Keep")
	await click(editor.undo_button)
	await settled()
	check(await read() == authored, "Undo after Keep restores the exact authored build")
	await click(editor.redo_button)
	await settled()
	check(await read() == kept_bytes, "Redo re-applies the exact kept result")
	await click(editor.play_button)
	await settled()
	await frames(2)
	sim.request_ticks(10)
	await read()
	await click(editor.play_button)
	await settled()
	check(not editor.testing and await read() == kept_bytes, "Return after a later run restores the kept revision, not the older build")
	# Keeping an unchanged experiment does nothing.
	await click(editor.play_button)
	await settled()
	await frames(2)
	await click(editor.pause_button)
	await frames(2)
	var history_size: int = editor.undo_history.size()
	await click(editor.keep_button)
	await kept()
	check(editor.testing and editor.undo_history.size() == history_size and editor.edit_message.begins_with("Nothing changed"), "Keep with no changes stays in Test and adds no history")
	await click(editor.play_button)
	await settled()
	check(await read() == kept_bytes, "Return still restores the kept revision")
	_restore_input()
	await frames(2)
	print("EDITOR_HEAT_UI_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
