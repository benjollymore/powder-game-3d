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
	var baseline := PackedByteArray()
	for samples in [1, 16]:
		sim.upload(world.to_byte_array())
		start()
		for frame in 24:
			var end := point(Vector3i(n / 2 + frame % 7, n * 3 / 4, n / 2))
			for sample in samples:
				# More events traverse extra subframe positions but have exactly
				# the same source position before the next authoritative tick.
				var mouse := end + Vector2(20 * float(samples - sample - 1) / samples, 0)
				lab._sample(mouse)
				lab._flush()
			await tick(5)
		release()
		var bytes := await read()
		check(count(bytes) == 24, "%d samples/frame adds exactly 24 grains over 120 ticks (got %d)" % [samples, count(bytes)])
		check(lab.pending.is_empty() and lab.pending_surface.is_empty(), "live drag leaves no immediate geometry queue")
		if baseline.is_empty():
			baseline = bytes
		else:
			check(bytes == baseline, "actual packed material state is identical with 1 or 16 pointer samples/frame")
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
