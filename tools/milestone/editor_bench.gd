extends SceneTree
## Visible-window workload benchmark. Requires the coordinator's GPU lease.
## godot --path . --always-on-top --disable-vsync --resolution 1600x900 \
##   -s res://tools/milestone/editor_bench.gd -- grid=128 frames=90
## Samples end at frame_post_draw, not a potentially occluded process loop.
var editor: Node3D
var sim: Node3D
var frames := 90
var warmup := 20
var results: Array[Dictionary] = []
var evidence_dir := "res://docs/milestone/editor-evidence"

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("frames="):
			frames = clampi(int(argument.substr(7)), 10, 600)
	create_timer(180.0).timeout.connect(func():
		push_error("Editor benchmark watchdog: visible rendered frames did not complete")
		quit(1))
	call_deferred("run")

func read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func run() -> void:
	DirAccess.make_dir_recursive_absolute(evidence_dir)
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	editor.set_process(false)
	editor.set_process_input(false)
	editor.set_process_unhandled_input(false)
	sim = editor.sim
	sim.listen_to_time_controller = false
	editor.yaw = 0.65
	editor.pitch = -0.4
	editor._update_camera()
	editor.marker.visible = false
	editor.guide.visible = false
	for i in 15:
		await RenderingServer.frame_post_draw
	var authored := await read()
	root.get_texture().get_image().save_png(evidence_dir.path_join("grid-%d-initial.png" % VoxelCodec.GRID))
	print("EDITOR_BENCH config=", JSON.stringify({"grid": VoxelCodec.GRID,
		"resolution": str(root.size), "frames": frames, "warmup": warmup,
		"ticks_per_running_frame": 2, "physical_tick_seconds": sim.seconds_per_tick}))
	for workload in ["paused", "running", "paused_paint", "running_paint", "surface_paint"]:
		results.append(await measure(workload, authored))
	print("EDITOR_BENCH results=", JSON.stringify(results))
	quit(0)

func measure(workload: String, authored: PackedByteArray) -> Dictionary:
	sim.upload(authored)
	await read()
	var samples: Array[float] = []
	var paint := workload.ends_with("paint")
	var running := workload.begins_with("running")
	var surface := workload == "surface_paint"
	var transaction := -1
	var transaction_result: Dictionary = {}
	if paint and not running:
		transaction = sim.begin_edit_transaction(func(result: Dictionary):
			transaction_result.merge(result, true))
	var n := VoxelCodec.GRID
	var drawn_before := Engine.get_frames_drawn()
	for frame in warmup + frames:
		var start := Time.get_ticks_usec()
		if paint:
			var center := Vector3i(n / 3 + frame % (n / 3), n / 2, n / 2)
			var centers: Array[Vector3i] = [center]
			if running:
				sim.set_live_emitter(center, 3, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 24.0, 42)
			elif surface:
				# The camera ray targets the back wall of the actual editor bowl.
				# This includes authoritative GPU pick fencing and regional history.
				var point: Vector3 = Vector3(float(center.x) / n - 0.5, 0.0, -0.25) * sim.world_size()
				var ray: Dictionary = editor._ray_at(editor.camera.unproject_position(point))
				ray["connect"] = true
				sim.record_surface_stroke(transaction, [ray], 3, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 42)
			else:
				sim.record_stroke(transaction, centers, 3, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 42)
		if running:
			sim.request_ticks(2)
		await RenderingServer.frame_post_draw
		if frame >= warmup:
			samples.append((Time.get_ticks_usec() - start) / 1000.0)
	if running:
		sim.clear_live_emitter()
	var history_finish_ms := 0.0
	if transaction >= 0:
		var start := Time.get_ticks_usec()
		sim.finish_edit_transaction(transaction)
		while transaction_result.is_empty():
			await process_frame
		history_finish_ms = (Time.get_ticks_usec() - start) / 1000.0
		if not transaction_result.valid:
			push_error("Benchmark history failed: " + transaction_result.error)
			quit(1)
	var bytes := await read()
	var drawn_after := Engine.get_frames_drawn()
	var capture := root.get_texture().get_image()
	capture.save_png(evidence_dir.path_join("grid-%d-%s.png" % [VoxelCodec.GRID, workload]))
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	var total := 0.0
	for sample in samples:
		total += sample
	samples.sort()
	var result := {"workload": workload, "mean_ms": total / samples.size(),
		"median_ms": samples[samples.size() / 2],
		"p95_ms": samples[mini(samples.size() - 1, ceili(samples.size() * 0.95) - 1)],
		"max_ms": samples.back(), "history_bytes": transaction_result.get("bytes", 0),
		"history_finish_ms": history_finish_ms, "requested_ticks": sim.tick,
		"frames_drawn_including_history_and_readback": drawn_after - drawn_before,
		"capture_size": str(capture.get_size()),
		"voxel_sha256": digest.finish().hex_encode()}
	print("EDITOR_BENCH case=", JSON.stringify(result))
	return result
