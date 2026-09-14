extends "res://tests/milestone/editor_workflow_gpu.gd"
## Scene→toolbar→scene motions occur before any process frame, as can happen
## with high-rate pointer events. Both production frame loops remain enabled.
func changed_cells(before: PackedByteArray, after: PackedByteArray) -> Array[Vector3i]:
	var changed: Array[Vector3i] = []
	var n := VoxelCodec.GRID
	for offset in range(0, before.size(), 4):
		if before.decode_u32(offset) != after.decode_u32(offset):
			var cell := offset / 4
			changed.append(Vector3i(cell % n, (cell / n) % n, cell / (n * n)))
	return changed
func cross_toolbar(first: Vector3i, last: Vector3i) -> void:
	move_to(point(first))
	await frames(2)
	mouse(true)
	move_to(editor.tools_panel.get_global_rect().get_center())
	move_to(point(last))
	mouse(false)
	await settled()
func run() -> void:
	output_dir = "/tmp/editor-gui-crossing"
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
	check(editor.is_processing() and clock.is_processing(), "production editor and time loops remain active during high-rate GUI crossings")
	var n := VoxelCodec.GRID
	editor.radius_input.value = 0
	await click(editor.material_buttons[Elements.Id.SAND])
	var original := await read()
	var first := Vector3i(n * 7 / 8, n * 3 / 4, n / 2)
	var last := Vector3i(n * 7 / 8, n * 5 / 8, n / 2)
	await cross_toolbar(first, last)
	var painted := await read()
	var cells := changed_cells(original, painted)
	print("PLANE_CHANGED_CELLS ", cells)
	check(cells.size() == 2 and first in cells and last in cells,
		"same-frame workplane→toolbar→workplane paints only the two endpoints, never an invented connector")
	check(id_at(painted, first) == Elements.Id.SAND and id_at(painted, last) == Elements.Id.SAND and editor.undo_history.size() == 1,
		"reentry remains the same authored gesture with the selected material")
	await click(editor.undo_button)
	await settled()
	check(await read() == original, "Undo restores every packed byte before the interrupted workplane stroke")
	await click(editor.redo_button)
	await settled()
	check(await read() == painted, "Redo restores the interrupted workplane stroke byte for byte")
	# Flat exposed wall makes surface continuation observable: without event-time
	# breaking the two hits share a normal/depth and incorrectly become one line.
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(n / 4, n / 4, n / 2), Vector3i(n * 3 / 4, n * 3 / 4, n / 2 + 1), Elements.Id.WALL)
	editor.replace_authored(data.to_byte_array())
	editor._set_section(false)
	editor._set_target_mode(editor.TargetMode.SURFACE)
	original = await read()
	first = Vector3i(n / 2, n * 5 / 8, n / 2)
	last = Vector3i(n / 2, n * 3 / 8, n / 2)
	await cross_toolbar(first, last)
	painted = await read()
	cells = changed_cells(original, painted)
	print("SURFACE_CHANGED_CELLS ", cells)
	check(cells.size() == 2 and first + Vector3i.BACK in cells and last + Vector3i.BACK in cells,
		"same-frame surface→toolbar→surface cannot bridge the skipped pointer path")
	check(preserved_walls(original, painted) and editor.undo_history.size() == 1,
		"surface segment break preserves every original wall and one authored transaction")
	await click(editor.undo_button)
	await settled()
	check(await read() == original, "Undo restores exact pre-surface bytes")
	await click(editor.redo_button)
	await settled()
	check(await read() == painted, "Redo restores the interrupted surface stroke byte for byte")
	editor.replace_authored(original)
	await click(editor.play_button)
	await settled()
	await click(editor.pause_button)
	move_to(point(first))
	await frames(2)
	var before_live := await read()
	mouse(true)
	check(editor.painting and editor.live_emitter_signature != 0, "paused Test press registers a live source")
	move_to(editor.tools_panel.get_global_rect().get_center())
	check(editor.live_emitter_signature == 0, "toolbar motion cancels the source immediately, before a process frame")
	# Queue the authoritative tick now, before _process can observe GUI hover.
	sim.request_ticks(1)
	mouse(false)
	var after_tick := await read()
	check(sim.histogram(after_tick)[Elements.Id.SAND] == 0 and after_tick == before_live,
		"next tick adds no stale material while the held pointer has entered the toolbar")
	await click(editor.play_button)
	await settled()
	check(await read() == original and not editor.testing, "Return retains the exact authored surface fixture")
	_restore_input()
	await frames(2)
	print("Editor GUI crossing GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
