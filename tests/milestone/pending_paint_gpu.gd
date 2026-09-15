extends "res://tests/milestone/editor_gui_crossing_gpu.gd"
## Actual async history and parsed engine input. Both production process loops
## remain active; no artificial delay or capture-completion stub is used.
var original: PackedByteArray
var dot: Vector3i
var first_read: Array = []
func history_key(redo := false) -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_Z
	event.ctrl_pressed = true
	event.shift_pressed = redo
	event.pressed = true
	Input.parse_input_event(event)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
func reset_build() -> void:
	await settled()
	editor.replace_authored(original)
	editor._set_target_mode(editor.TargetMode.PLANE)
	editor._face_plane()
	editor.radius_input.value = 0
	editor._choose_material(Elements.Id.SAND)
	first_read = []
	await frames(2)
func begin_pair(points: Array[Vector3i], release := true) -> void:
	move_to(point(dot))
	await frames(1)
	mouse(true)
	mouse(false)
	# Capture a reference after the first real mutation but before replay of the
	# waiting gesture. This full readback is a test oracle, not editor history.
	var reference: Array = first_read
	sim.request_readback(func(bytes): reference.append(bytes))
	move_to(point(points[0]))
	mouse(true)
	for i in range(1, points.size()):
		move_to(point(points[i]))
	if release:
		mouse(false)
func wait_file() -> void:
	while editor.archive_panel.operation != "":
		await process_frame
func matches_cells(before: PackedByteArray, after: PackedByteArray, expected: Array[Vector3i]) -> bool:
	var changed := changed_cells(before, after)
	if changed.size() != expected.size():
		return false
	for cell in changed:
		if cell not in expected:
			return false
	return true
func run() -> void:
	output_dir = "/tmp/editor-pending-paint"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="):
			output_dir = arg.trim_prefix("output_dir=")
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
	await frames(12)
	original = await read()
	var n := VoxelCodec.GRID
	dot = Vector3i(n * 7 / 8, n * 7 / 8, n / 2)
	var a := Vector3i(n * 13 / 16, n * 3 / 4, n / 2)
	var b := Vector3i(n * 15 / 16, n * 3 / 4, n / 2)
	var c := Vector3i(n * 15 / 16, n * 5 / 8, n / 2)
	var curve: Array[Vector3i] = [a, b, c]
	await reset_build()
	check(editor.is_processing() and clock.is_processing(), "production process loops remain enabled through deferred authored gestures")
	await begin_pair(curve)
	check(editor.capturing and editor.pending_authored != null and editor.pending_authored.closed and editor.pending_authored.samples.size() == 3,
		"rapid released second stroke retains all curve samples while first history capture is pending")
	key(KEY_2) # Water: number keys follow the palette's first row (Sand, Water, Wall)
	key(KEY_BRACKETRIGHT)
	await settled()
	var painted := await read()
	var expected: Array[Vector3i] = [dot]
	for x in range(a.x, b.x + 1):
		expected.append(Vector3i(x, a.y, a.z))
	for y in range(c.y, b.y):
		expected.append(Vector3i(c.x, y, c.z))
	check(matches_cells(original, painted, expected), "deferred L-shaped stroke paints the exact curve, with no diagonal shortcut or enlarged radius")
	var all_sand := true
	for cell in expected:
		all_sand = all_sand and id_at(painted, cell) == Elements.Id.SAND
	check(all_sand and editor.element == Elements.Id.WATER and editor.radius == 1 and editor.undo_history.size() == 2,
		"waiting stroke retains Sand/radius-zero metadata despite later tool changes, and gets its own Undo")
	await click(editor.undo_button)
	await settled()
	check(first_read.size() == 1 and await read() == first_read[0], "Undo removes only the deferred stroke and restores the first edit's exact packed bytes")
	await click(editor.redo_button)
	await settled()
	check(await read() == painted, "Redo restores the exact deferred curve, seeds and amounts")
	# A held stroke begun during Undo must resume after the inverse is validated.
	await click(editor.material_buttons[Elements.Id.SAND])
	editor.radius_input.value = 0
	move_to(point(a))
	history_key()
	mouse(true)
	move_to(point(b))
	check(editor.pending_authored != null and not editor.pending_authored.closed, "press and motion during asynchronous Undo create one open pending gesture")
	for i in 120:
		if editor.painting and editor.pending_authored == null:
			break
		await process_frame
	check(editor.painting and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT), "continued parsed Input hold resumes painting after Undo instead of being silently dropped")
	move_to(point(c))
	mouse(false)
	await settled()
	var after_undo_gesture := await read()
	check(matches_cells(original, after_undo_gesture, expected) and editor.redo_history.is_empty() and editor.undo_history.size() == 2,
		"gesture after Undo continues its full curve and branches only the obsolete Redo history")
	await click(editor.undo_button)
	await settled()
	check(await read() == first_read[0], "resumed held gesture still undoes independently and exactly")
	var d := Vector3i(n * 13 / 16, n * 5 / 8, n / 2)
	move_to(point(d))
	history_key(true)
	mouse(true)
	mouse(false)
	check(editor.pending_authored != null and editor.pending_authored.closed, "short click during Redo is retained even when released before inverse capture completes")
	await settled()
	expected.append(d)
	check(matches_cells(original, await read(), expected) and editor.undo_history.size() == 3,
		"Redo restores its stroke before the new queued click becomes a separate authored edit")
	# Toolbar gaps are retained inside a pending curve too.
	await reset_build()
	await begin_pair([a], false)
	move_to(editor.tools_panel.get_global_rect().get_center())
	move_to(point(c))
	mouse(false)
	await settled()
	check(matches_cells(original, await read(), [dot, a, c]), "pending gesture preserves an event-time toolbar gap without inventing a connector")
	# A second waiting gesture is rejected explicitly; the queue cannot grow.
	await reset_build()
	await begin_pair([a])
	move_to(point(c))
	mouse(true)
	mouse(false)
	check(editor.pending_authored != null and editor.pending_authored.samples.size() == 1 and editor.edit_message.contains("already waiting"),
		"one pending gesture is a hard queue bound with immediate feedback for extra presses")
	await settled()
	check(matches_cells(original, await read(), [dot, a]) and editor.edit_message.contains("skipped"),
		"queue overflow preserves the accepted gesture and leaves a persistent skipped-stroke explanation")
	await reset_build()
	await begin_pair(curve)
	history_key()
	await settled()
	check(await read() == first_read[0] and editor.undo_history.size() == 1 and editor.pending_authored == null,
		"Undo cancels the newest waiting stroke without also undoing the earlier applied edit")
	history_key()
	await settled()
	check(await read() == original, "a second Undo reaches the earlier applied edit normally")
	# Surface gestures retain their full ray curve and resolve against ordered
	# authoritative state only after the prior history capture completes.
	var bowl := original
	var bowl_dot := dot
	var wall := WorldBuilder.empty()
	WorldBuilder.fill_box(wall, Vector3i(n / 4, n / 4, n / 2), Vector3i(n * 3 / 4, n * 3 / 4, n / 2 + 1), Elements.Id.WALL)
	original = wall.to_byte_array()
	dot = Vector3i(n * 5 / 8, n * 11 / 16, n / 2)
	await reset_build()
	editor._set_section(false)
	editor._set_target_mode(editor.TargetMode.SURFACE)
	var sa := Vector3i(n * 3 / 8, n * 5 / 8, n / 2)
	var sb := Vector3i(n * 5 / 8, n * 5 / 8, n / 2)
	var sc := Vector3i(n * 5 / 8, n * 3 / 8, n / 2)
	await begin_pair([sa, sb, sc])
	check(editor.pending_authored != null and editor.pending_authored.metadata.mode == editor.TargetMode.SURFACE,
		"surface gesture waits as frozen rays while the earlier surface edit captures history")
	await settled()
	var surface_painted := await read()
	var surface_expected: Array[Vector3i] = [dot + Vector3i.BACK]
	for x in range(sa.x, sb.x + 1):
		surface_expected.append(Vector3i(x, sa.y, sa.z + 1))
	for y in range(sc.y, sb.y):
		surface_expected.append(Vector3i(sc.x, y, sc.z + 1))
	check(matches_cells(original, surface_painted, surface_expected) and preserved_walls(original, surface_painted),
		"deferred surface curve resolves exact outside cells without erasing or shortcutting through the wall")
	await click(editor.undo_button)
	await settled()
	check(await read() == first_read[0], "deferred surface curve undoes to exact prior packed material")
	await click(editor.redo_button)
	await settled()
	check(await read() == surface_painted, "deferred surface curve redo restores exact seeds and amounts")
	original = bowl
	dot = bowl_dot
	# Latest navigation/phase/modal/world intentions invalidate pending placement.
	for boundary in ["navigation", "modal", "world", "phase"]:
		await reset_build()
		await begin_pair(curve)
		match boundary:
			"navigation": key(KEY_F)
			"modal": editor.archive_panel._begin_modal()
			"world": sim.upload(original)
			"phase":
				key(KEY_SPACE)
				move_to(point(c))
				mouse(true)
				mouse(false)
				check(editor.pending_authored == null, "paint during queued Run preparation is not replayed later into Test")
		await settled()
		if boundary == "modal":
			editor.archive_panel._end_modal()
		if boundary == "phase":
			check(editor.testing and editor.build_snapshot == first_read[0] and editor.pending_authored == null,
				"Run captures the completed earlier edit without replaying canceled pending Build paint into Test")
			await click(editor.play_button)
			await settled()
		else:
			var wanted: PackedByteArray = original if boundary == "world" else first_read[0]
			check(await read() == wanted and editor.pending_authored == null,
				"%s boundary cancels pending authored placement before it can mutate a new context" % boundary)
	# Open may finish while the user initiates history and another gesture.
	await reset_build()
	await begin_pair([a])
	await settled()
	var path := output_dir.path_join("open-oracle.p3d")
	check(WorldArchive.save_authored(path, original, n).ok, "saved fixture is available for asynchronous Open completion")
	editor.archive_panel.open_path(path)
	move_to(point(c))
	history_key()
	mouse(true)
	mouse(false)
	await settled()
	await wait_file()
	check(matches_cells(original, await read(), [dot, c]) and editor.archive_panel.message.text.contains("changed"),
		"Open completion cannot overwrite a newer Undo plus queued authored gesture")
	DirAccess.remove_absolute(path)
	_restore_input()
	await frames(2)
	print("Pending paint GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
