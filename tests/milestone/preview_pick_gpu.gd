extends "res://tests/milestone/editor_workflow_gpu.gd"
## Placement-brief contract 3: preview picks every frame, ids that only move
## forward, a target that stays visible while the pointer moves, and batch
## picks that equal single picks. Parsed pointer events plus the real editor
## and simulator loops; the OS cursor is synchronized and restored.
signal batch_ready(results: Array)
signal single_ready(result: Dictionary)

func wall_ray(x: int, y: int) -> Dictionary:
	return {"origin": Vector3((x + 0.5) / VoxelCodec.GRID - 0.5, (y + 0.5) / VoxelCodec.GRID - 0.5, 1.0),
		"direction": Vector3.FORWARD, "section": false, "axis": 2, "depth": VoxelCodec.GRID - 1}

func run() -> void:
	output_dir = "/tmp/editor-preview-pick"
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
	var n := VoxelCodec.GRID
	# A flat wall slab facing the default camera plus a raised block, so a drag
	# crosses a height change without leaving material. The slab sits well
	# below the default cutaway depth (n / 2): a radius-three cap painted on it
	# must never reach the cut plane, where an add target is legitimately
	# blocked and the marker legitimately hides (surface-feedback contract).
	var data := WorldBuilder.empty()
	var floor_z := n / 4
	WorldBuilder.fill_box(data, Vector3i(n / 8, n / 8, floor_z), Vector3i(n * 7 / 8, n * 7 / 8, floor_z + 1), Elements.Id.WALL)
	WorldBuilder.fill_box(data, Vector3i(n / 2 - 4, n / 2 - 4, floor_z + 1), Vector3i(n / 2 + 4, n / 2 + 4, floor_z + 5), Elements.Id.WALL)
	sim.upload(data.to_byte_array())
	await frames(4)
	var original := await read()
	editor._set_target_mode(editor.TargetMode.SURFACE)
	await click(editor.material_buttons[Elements.Id.SAND])
	# Radius zero: a surface brush wider than the per-frame drag distance lands
	# each pick on the previous frame's cap and climbs its own paint toward the
	# camera (a real property of surface painting, outside this suite); one
	# cell per frame keeps every pick on the slab so validity is what is measured.
	while editor.radius > 0:
		key(KEY_BRACKETLEFT)
		await frames(1)
	check(editor.radius == 0, "drag uses a radius-zero brush")
	var start := Vector3i(n / 4, n / 2, floor_z + 1)
	var finish := Vector3i(n * 3 / 4, n / 2, floor_z + 1)
	move_to(point(start))
	var warm := 0
	while not editor.pick_cache.get("valid", false) and warm < 30:
		await frames(1)
		warm += 1
	await frames(1) # the deferred pick delivery lands after _process; the marker follows next frame
	check(editor.pick_cache.get("valid", false) and editor.marker.visible, "stationary hover over the wall obtains a visible surface target (%d frames)" % warm)
	# 60-frame parsed drag with the button held: every frame must show a target.
	var hidden := 0
	var stale_ids := 0
	var last_shown: int = editor.pick_shown_id
	mouse(true)
	var trace: Array = []
	for i in 60:
		move_to(point(start).lerp(point(finish), float(i + 1) / 60.0))
		await frames(1)
		if editor.target.x < 0 or not editor.marker.visible:
			hidden += 1
			trace.append("frame %d target=%s valid=%s cache_empty=%s pending=%s shown=%d req=%d over_ui=%s orbiting=%s painting=%s capturing=%s hit=%s normal=%s" % [i, editor.target, editor.pick_cache.get("valid", null), editor.pick_cache.is_empty(), editor.pick_pending, editor.pick_shown_id, editor.pick_request_id, editor.get_viewport().gui_get_hovered_control() != null, editor.orbiting, editor.painting, editor.capturing, editor.pick_cache.get("hit", null), editor.pick_cache.get("normal", null)])
	for line in trace:
		print("HIDDEN ", line)
		if editor.pick_shown_id < last_shown:
			stale_ids += 1
		last_shown = editor.pick_shown_id
	mouse(false)
	await settled()
	check(hidden == 0, "target stays visible on every frame of a 60-frame drag (%d hidden)" % hidden)
	check(stale_ids == 0 and editor.pick_shown_id > 0, "shown pick ids only move forward during the drag")
	check(editor.pick_request_id >= 30, "picks are issued while the pointer moves (%d requests over the drag)" % editor.pick_request_id)
	var painted := await read()
	check(painted != original and preserved_walls(original, painted), "the drag painted onto the surface and preserved every wall cell")
	# A newer target replaces the older one within a frame of arriving.
	var far := Vector3i(n / 4, n / 4, floor_z + 1)
	var before_id: int = editor.pick_shown_id
	move_to(point(far))
	var waited := 0
	while editor.pick_shown_id <= before_id and waited < 8:
		await frames(1)
		waited += 1
	sim.request_surface_pick(editor._ray_at(point(far)), editor.radius, false, func(result): single_ready.emit(result))
	var expected: Dictionary = await single_ready
	check(editor.pick_shown_id > before_id and waited <= 4, "a newer pick replaces the shown target within a few frames (%d)" % waited)
	check(expected.valid and (editor.target - expected.target).length() <= 1.0, "the replaced target matches a fresh pick of the same ray (%s vs %s)" % [editor.target, expected.target])
	# Batch of 32 rays equals 32 single picks.
	var rays: Array = []
	for i in 32:
		rays.append(wall_ray(n / 8 + 1 + i * 2, n / 2 + (i % 5) - 2))
	sim.request_surface_picks(rays, func(results): batch_ready.emit(results))
	var batch: Array = await batch_ready
	var equal := batch.size() == 32
	for i in 32:
		sim.request_surface_pick(rays[i], 0, false, func(result): single_ready.emit(result))
		var single: Dictionary = await single_ready
		var b: Dictionary = batch[i] if i < batch.size() else {}
		equal = equal and b.get("valid", false) == single.valid and b.get("hit", Vector3i(-2, -2, -2)) == single.hit and b.get("normal", Vector3i.ZERO) == single.normal and b.get("target", Vector3i(-2, -2, -2)) == single.target and b.get("index", -1) == i
	check(equal, "a batch of 32 rays returns 32 records matching 32 single picks in order")
	var mixed: Array = [rays[0], {"origin": Vector3.ZERO, "direction": Vector3.ZERO}, rays[1]]
	sim.request_surface_picks(mixed, func(results): batch_ready.emit(results))
	var partial: Array = await batch_ready
	check(partial.size() == 3 and partial[0].valid and not partial[1].valid and partial[2].valid and partial[2].index == 2, "invalid rays in a batch decode as misses in their own slot")
	check(await read() == painted, "preview picking leaves the painted world unchanged")
	_restore_input()
	await frames(2)
	print("PREVIEW_PICK_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
