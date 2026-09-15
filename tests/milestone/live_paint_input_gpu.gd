extends SceneTree
## Editor-level physical result, with different input sampling densities on the
## same tick-positioned path. This intentionally exercises _sample AND _flush.
var lab: Node3D
var sim: Node3D
var checks := 0
var failures := 0
func _initialize() -> void:
	root.size = Vector2i(1280, 800)
	create_timer(90.0).timeout.connect(func():
		push_error("Live paint input watchdog expired")
		quit(1))
	lab = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	_run()
func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1
func read() -> PackedByteArray:
	await process_frame
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready
func tick(amount: int) -> void:
	sim.request_ticks(amount)
	await process_frame
	sim.request_layer_counts()
	await sim.layer_counts_ready
func point(cell: Vector3i) -> Vector2:
	return lab.camera.unproject_position(sim.to_global((Vector3(cell) + Vector3.ONE * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5))
func count(bytes: PackedByteArray) -> int:
	var grains := 0
	for i in range(0, bytes.size(), 4):
		if bytes[i] == Elements.Id.SAND:
			grains += 1
	return grains
func release() -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = false
	lab._input(event)
func start() -> void:
	lab.testing = true
	lab.painting = true
	lab.stroke_target_mode = lab.TargetMode.PLANE
	lab.stroke_radius = 0
	lab.stroke_element = Elements.Id.SAND
	lab.stroke_erase = false
	lab.previous = Vector3i(-1, -1, -1)
func _run() -> void:
	for i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/editor-paint-tools-1280x800.png")
	sim = lab.sim
	lab.set_process(false) # _ready enables script processing after initial tree insertion.
	check(sim.has_method("finish_live_emitter"), "integrated simulation provides tick-owned click completion")
	if failures:
		quit(1)
		return
	sim.seconds_per_tick = 1.0 / 120.0
	var n := VoxelCodec.GRID
	lab.depth = n / 2
	var world := WorldBuilder.empty()
	WorldBuilder.fill_box(world, Vector3i(1, 1, 1), Vector3i(n - 1, 2, n - 1), Elements.Id.WALL)
	# A slow drag of one cell per frame: the source stamps once per frame at
	# the new cell and the crossed-path stamp lands on the same cell first, so
	# the physical result is exactly one grain per frame, whatever the number
	# of pointer events within the frame.
	var baseline := PackedByteArray()
	for samples in [1, 16]:
		sim.upload(world.to_byte_array())
		start()
		for frame in 24:
			var end := point(Vector3i(n / 2 - 12 + frame, n * 3 / 4, n / 2))
			for sample in samples:
				# More events within the frame at the same position: a source
				# is metered by ticks, not by pointer events.
				lab._sample(end)
				lab._flush()
			await tick(5)
		release()
		var bytes := await read()
		check(count(bytes) == 24, "%d samples/frame slow drag adds exactly 24 grains over 120 ticks (got %d)" % [samples, count(bytes)])
		check(lab.pending.is_empty() and lab.pending_surface.is_empty(), "live drag leaves no immediate geometry queue")
		if baseline.is_empty():
			baseline = bytes
		else:
			check(bytes == baseline, "actual packed material state is identical with 1 or 16 pointer samples/frame")
	# A still pointer attempts exactly 24 source stamps; ONLY_AIR deposits only
	# when the cell is free, so the grain count is bounded by the attempts and
	# identical across event densities (the simulation is deterministic).
	var still := PackedByteArray()
	for samples in [1, 16]:
		sim.upload(world.to_byte_array())
		start()
		var end := point(Vector3i(n / 2, n * 3 / 4, n / 2))
		for frame in 24:
			for sample in samples:
				lab._sample(end)
				lab._flush()
			await tick(5)
		release()
		var bytes := await read()
		check(sim._rt_live_emitter_stamps == 24 and count(bytes) <= 24 and count(bytes) > 0, "%d samples/frame still pointer attempts exactly 24 source stamps over 120 ticks (%d attempts, %d grains)" % [samples, sim._rt_live_emitter_stamps, count(bytes)])
		if still.is_empty():
			still = bytes
		else:
			check(bytes == still, "still-pointer result is identical with 1 or 16 pointer samples/frame")
	# A moving brush lays a connected line: every cell it crosses gets a stamp
	# inside the next tick, in addition to the source's own rate. A wall shelf
	# under the path keeps each grain where it landed.
	var path_y := n * 3 / 4
	var shelf := world.duplicate()
	WorldBuilder.fill_box(shelf, Vector3i(n / 4, path_y - 1, n / 2 - 2), Vector3i(3 * n / 4, path_y, n / 2 + 3), Elements.Id.WALL)
	var moving := PackedByteArray()
	for samples in [1, 16]:
		sim.upload(shelf.to_byte_array())
		start()
		var x0 := n / 2 - 20
		# Both densities start at x0 and end at x0 + 40; only the intermediate
		# sample count differs.
		for frame in 8:
			for sample in samples:
				var t: float = float(frame * samples + sample) / float(8 * samples)
				var cell := Vector3i(x0 + int(round(40.0 * t)), path_y, n / 2)
				lab._sample(point(cell))
				lab._flush()
			if frame == 7:
				lab._sample(point(Vector3i(x0 + 40, path_y, n / 2)))
				lab._flush()
			await tick(5)
		release()
		await tick(1)
		var bytes := await read()
		var missing: Array[int] = []
		for x in range(x0, x0 + 41):
			if bytes[VoxelCodec.index(x, path_y, n / 2) * 4] != Elements.Id.SAND:
				missing.append(x - x0)
		check(missing.is_empty(), "%d samples/frame moving brush deposits on every crossed cell (missing offsets %s)" % [samples, str(missing)])
		if moving.is_empty():
			moving = bytes
		else:
			check(bytes == moving, "a straight moving path deposits the same cells with 1 or 16 samples/frame")
	# Press/release before any tick still emits exactly once at the next tick.
	sim.upload(world.to_byte_array())
	start()
	lab._sample(point(Vector3i(n / 2, n * 3 / 4, n / 2)))
	release()
	check(count(await read()) == 0, "quick click does not inject outside a simulation tick")
	await tick(1)
	check(count(await read()) == 1, "quick click paints once on the next tick")
	await tick(15)
	check(count(await read()) == 1, "completed quick click does not leave a held emitter")
	# Surface mode also keeps pointer samples out of the geometry dispatch path.
	WorldBuilder.fill_box(world, Vector3i(n / 2 - 8, n / 2 - 8, n / 2 - 8), Vector3i(n / 2 + 9, n / 2 + 9, n / 2 - 7), Elements.Id.WALL)
	sim.upload(world.to_byte_array())
	start()
	lab.stroke_target_mode = lab.TargetMode.SURFACE
	lab.stroke_view = {"section": false, "axis": 2, "depth": n - 1}
	for i in 20:
		lab._sample(point(Vector3i(n / 2, n / 2, n / 2)))
		lab._flush()
	check(count(await read()) == 0 and lab.pending_surface.is_empty(), "surface pointer input cannot bypass the tick-owned source either")
	lab._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await tick(1)
	check(count(await read()) == 0, "focus cancellation adds no deferred click")
	print("Live paint input GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
