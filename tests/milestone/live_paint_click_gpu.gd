extends "res://tests/milestone/editor_workflow_gpu.gd"
## Live painting through the REAL click path: the production editor with its own
## _input and _process running, the Run button pressed as a person presses it,
## then press, drag and release over the world. The existing live-paint suites
## set `testing` and `painting` on the editor directly and disable `_process`,
## so they cannot see a regression in the press handler or the frame loop.

func grains(bytes: PackedByteArray, id: int) -> int:
	var total := 0
	for i in range(0, bytes.size(), 4):
		if bytes[i] == id:
			total += 1
	return total


## A slab of wall to aim at, uploaded as the authored world.
func _set_surface_floor(n: int) -> void:
	var data := WorldBuilder.empty()
	for z in range(n / 4, 3 * n / 4):
		for y in range(n / 4 - 3, n / 4 + 1):
			for x in range(n / 4, 3 * n / 4):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WALL, 17, 0)
	sim.upload(data.to_byte_array())
	await frames(4)


func run() -> void:
	output_dir = "/tmp/live-paint-click"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="):
			output_dir = arg.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(output_dir)
	original_cursor = DisplayServer.mouse_get_position()
	original_accumulation = Input.use_accumulated_input
	input_configured = true
	Input.use_accumulated_input = false
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	clock = root.get_node("TimeController")
	await frames(12)
	check(editor.is_processing() and clock.is_processing(), "production editor and time loops remain enabled")

	var n := VoxelCodec.GRID
	await click(editor.material_buttons[Elements.Id.SAND])
	check(editor.element == Elements.Id.SAND, "Sand is the selected material")

	# Enter Test exactly as a person does.
	await click(editor.play_button)
	await settled()
	await frames(4)
	check(editor.testing, "the Run button enters Test")

	var before := await read()
	var first := Vector3i(n * 7 / 16, n * 3 / 4, n / 2)
	var last := Vector3i(n * 9 / 16, n * 3 / 4, n / 2)

	move_to(point(first))
	await frames(2)
	mouse(true)
	await frames(4)
	check(editor.painting, "a press over the world starts live painting")
	check(editor.live_emitter_signature != 0, "the press arms a live source")

	move_to(point(last))
	await frames(4)
	mouse(false)
	await frames(2)

	# Let authoritative ticks deposit and the grains fall clear of the source.
	for i in 6:
		sim.request_ticks(20)
		await frames(2)
	var after := await read()
	var added := grains(after, Elements.Id.SAND) - grains(before, Elements.Id.SAND)
	check(added > 0, "pressing and dragging during Run places material (%d cells added)" % added)

	# Surface targeting during Run, over real material: the natural way to paint
	# onto an existing build, and the path that carries the new stroke mask.
	await _set_surface_floor(n)
	editor._set_target_mode(editor.TargetMode.SURFACE)
	await frames(4)
	check(editor.targeting_mode == editor.TargetMode.SURFACE, "Paint on: material surface is selected")
	var floor_before := await read()
	var floor_top := Vector3i(n / 2, n / 4, n / 2)
	move_to(point(floor_top + Vector3i(0, 1, 0)))
	await frames(6)
	mouse(true)
	await frames(6)
	check(editor.painting, "a press over a surface starts live painting")
	move_to(point(floor_top + Vector3i(6, 1, 0)))
	await frames(6)
	mouse(false)
	await frames(2)
	for i in 6:
		sim.request_ticks(20)
		await frames(2)
	var floor_after := await read()
	var surface_added := grains(floor_after, Elements.Id.SAND) - grains(floor_before, Elements.Id.SAND)
	check(surface_added > 0, "pressing and dragging on a surface during Run places material (%d cells added)" % surface_added)

	# A Line or Box left active must not silently swallow every click in Run.
	# Both tools are new in this milestone and build the authored construction
	# only, so entering Test has to put the brush back in the user's hand.
	editor._set_target_mode(editor.TargetMode.PLANE)
	await frames(2)
	await click(editor.play_button) # back to Build
	await settled()
	editor._set_tool("line")
	await frames(2)
	check(editor.tool_mode == "line", "the Line tool is active in Build")
	await click(editor.play_button) # into Test with the tool still selected
	await settled()
	await frames(4)
	check(editor.testing, "Run entered with a tool selected")
	check(editor.tool_mode == "", "entering Run puts the brush back in the user's hand")
	var tool_before := await read()
	move_to(point(Vector3i(n * 7 / 16, n * 3 / 4, n / 2)))
	await frames(2)
	mouse(true)
	await frames(4)
	move_to(point(Vector3i(n * 9 / 16, n * 3 / 4, n / 2)))
	await frames(4)
	mouse(false)
	await frames(2)
	for i in 6:
		sim.request_ticks(20)
		await frames(2)
	var tool_after := await read()
	var after_tool := grains(tool_after, Elements.Id.SAND) - grains(tool_before, Elements.Id.SAND)
	check(after_tool > 0, "painting during Run still works after a tool was left selected (%d cells added)" % after_tool)

	await capture("live-paint-click")
	_restore_input()
	await frames(2)
	print("LIVE_PAINT_CLICK_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
