## Line and Box tools on the real editor (docs/milestone/placement-brief.md
## contract 7): two parsed clicks change exactly the expected cells as one
## undo entry, walls are preserved, and Undo restores the bytes.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/placement_tools_gpu.gd -- grid=128 output_dir=/tmp/placement-tools
extends "res://tests/milestone/preview_cells_gpu.gd"
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")

func key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)

func click_cell(cell: Vector3i) -> void:
	move_to(point(cell))
	await frames(2)
	mouse(true)
	await frames(1)
	mouse(false)
	await frames(2)

func expected_line(a: Vector3i, b: Vector3i, radius: int, shape: int, axis: int, before: PackedByteArray) -> Dictionary:
	var cells := {}
	for center in Geometry.stroke(a, b):
		for dx in range(-radius, radius + 1):
			for dy in range(-radius, radius + 1):
				for dz in range(-radius, radius + 1):
					var d := Vector3i(dx, dy, dz)
					var inside := true
					if shape == BrushScript.Shape.SPHERE:
						inside = dx * dx + dy * dy + dz * dz <= radius * radius
					elif shape == BrushScript.Shape.DISC:
						inside = d[axis] == 0
					if not inside:
						continue
					var p := center + d
					if VoxelCodec.in_bounds(p) and before[VoxelCodec.index(p.x, p.y, p.z) * 4] == 0:
						cells[p] = true
	return cells

func run() -> void:
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
	sim = editor.sim
	await frames(12)
	var n: int = VoxelCodec.GRID
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(n / 2 + 4, n / 2 - 2, editor.depth - 2), Vector3i(n / 2 + 8, n / 2 + 2, editor.depth + 3), Elements.Id.WALL)
	sim.upload(data.to_byte_array())
	await frames(6)
	editor._set_target_mode(editor.TargetMode.PLANE)
	editor.radius_input.value = 1
	var before := await read()
	var undo_before: int = editor.undo_history.size()
	# Line with a cube brush across a wall block: exactly the path's air cells change.
	editor._choose_material(Elements.Id.WALL)
	check(editor.shape == BrushScript.Shape.CUBE, "Wall selects the cube brush")
	key(KEY_L)
	check(editor.tool_mode == "line" and editor.line_button.button_pressed, "L enters line mode on the real editor")
	var a := Vector3i(n / 2 - 12, n / 2, editor.depth)
	var b := Vector3i(n / 2 + 14, n / 2 + 3, editor.depth)
	await click_cell(a)
	check(editor.tool_anchor == a, "first parsed click anchors the line at the targeted cell")
	await click_cell(b)
	await settled()
	var after := await read()
	var changed := changed_ids(before, after)
	var want := expected_line(a, b, 1, BrushScript.Shape.CUBE, editor.axis, before)
	check(same_set(changed.keys(), want), "second click stamps the cube along the connected line into air only (%d changed, %d expected)" % [changed.size(), want.size()])
	check(editor.undo_history.size() == undo_before + 1, "the line is one undo entry")
	var walls := true
	for i in range(0, after.size(), 4):
		if before[i] == Elements.Id.WALL and after[i] != Elements.Id.WALL:
			walls = false
	check(walls, "the line preserves the wall block it crosses")
	editor.undo_edit()
	await settled()
	check(await read() == before, "Undo restores the bytes from before the line")
	# Box with sand: half-open box between the two corners, air only.
	key(KEY_K)
	check(editor.tool_mode == "box" and editor.box_button.button_pressed and not editor.line_button.button_pressed, "K switches to box mode")
	editor._choose_material(Elements.Id.SAND)
	var c1 := Vector3i(n / 2 - 10, n / 2 - 6, editor.depth)
	var c2 := Vector3i(n / 2 - 3, n / 2 + 5, editor.depth)
	before = await read()
	undo_before = editor.undo_history.size()
	await click_cell(c1)
	check(editor.tool_anchor == c1 and editor.tool_box_mesh.visible == false or editor.tool_anchor == c1, "first box click anchors a corner")
	await click_cell(c2)
	await settled()
	after = await read()
	changed = changed_ids(before, after)
	var lo := c1.min(c2)
	var hi := c1.max(c2) + Vector3i.ONE
	var want_box := {}
	for x in range(lo.x, hi.x):
		for y in range(lo.y, hi.y):
			for z in range(lo.z, hi.z):
				if before[VoxelCodec.index(x, y, z) * 4] == 0:
					want_box[Vector3i(x, y, z)] = true
	check(same_set(changed.keys(), want_box), "box fills exactly the half-open box between the corners (%d changed, %d expected)" % [changed.size(), want_box.size()])
	check(editor.undo_history.size() == undo_before + 1, "the box is one undo entry")
	editor.undo_edit()
	await settled()
	check(await read() == before, "Undo restores the bytes from before the box")
	# Erase plus Box clears exactly the sand box just placed.
	await click_cell(c1)
	await click_cell(c2)
	await settled()
	var filled := await read()
	editor.erase = true
	undo_before = editor.undo_history.size()
	await click_cell(c1)
	await click_cell(c2)
	await settled()
	var cleared := await read()
	check(same_set(changed_ids(filled, cleared).keys(), want_box) and editor.undo_history.size() == undo_before + 1, "Box with Erase clears exactly the filled box as one undo entry")
	editor.erase = false
	# An anchor does not survive entering Test.
	await click_cell(c1)
	check(editor.tool_anchor == c1, "a box corner is anchored before Run")
	editor.run_or_restore()
	for i in 60:
		await process_frame
		if editor.testing:
			break
	check(editor.testing and editor.tool_anchor.x < 0, "entering Test drops the pending anchor")
	editor.run_or_restore()
	for i in 60:
		await process_frame
		if not editor.testing:
			break
	await settled()
	check(not editor.testing and editor.tool_anchor.x < 0, "Return leaves no anchor behind")
	key(KEY_K)
	check(editor.tool_mode == "", "K again returns to painting")
	_restore_input()
	await frames(2)
	print("PLACEMENT_TOOLS_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
