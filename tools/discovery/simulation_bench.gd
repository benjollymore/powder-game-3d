extends SceneTree
## Windowed deterministic baseline/coalesced experiment. See simulation.md.
## godot --path . --always-on-top --disable-vsync --resolution 1600x900 \
##   -s res://tools/discovery/simulation_bench.gd -- grid=256
var _sim: Node3D
var _frames := 120
var _warmup := 30
var _failures := 0

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("frames="):
			_frames = int(arg.substr(7))
	call_deferred("_run")

func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	_sim = scene.get_node("SimVolume")
	_sim.set_script(load("res://tools/discovery/deferred_sim.gd"))
	_sim.listen_to_time_controller = false
	root.add_child(scene)
	current_scene = scene
	scene.get_node("Brush").set_process(false)
	var rig: Node3D = scene.get_node("CameraRig")
	rig.frame_position = Vector3(0.85, 0.65, 0.85) * rig.world_size
	rig.frame_box(false)
	for i in 20:
		await RenderingServer.frame_post_draw
	print("CONFIG grid=%d warmup=%d measured=%d ticks/frame=2 seed=12345 resolution=%s" % [VoxelCodec.GRID, _warmup, _frames, root.size])
	# Every pair resets the same initial state and replays identical seeded edits.
	# Reverse order on repeat to expose order/thermal sensitivity.
	for repeat_index in 2:
		for workload in ["empty", "settled", "active", "painting", "paused_painting"]:
			var results := []
			var order := [false, true] if repeat_index == 0 else [true, false]
			for coalesce in order:
				results.append(await _case(workload, coalesce, repeat_index))
			var same_voxels: bool = results[0].voxels == results[1].voxels
			var same_air: bool = results[0].air == results[1].air
			print("EQUIVALENCE workload=%s repeat=%d voxels=%s air=%s" % [workload, repeat_index, same_voxels, same_air])
			if not same_voxels or not same_air:
				_failures += 1
	# Batch invariance is diagnostic, not a pass criterion for coalescing.
	for air_enabled in [false, true]:
		_sim.air_enabled = air_enabled
		var one: Dictionary = await _batch_case(1)
		var three: Dictionary = await _batch_case(3)
		print("BATCH_INVARIANCE scenario=Forest_fire ticks=60 air_enabled=%s voxels_equal=%s air_equal=%s one=%s three=%s" % [air_enabled, one.voxels == three.voxels, one.air == three.air, one, three])
	print("DISCOVERY failures=%d" % _failures)
	scene.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _ops(workload: String) -> Array:
	if workload == "empty":
		return []
	if workload == "settled":
		# A flat layer of sand supported by a wall floor is already at rest.
		var ops: Array = Scenarios.ops("Empty")
		ops.append({"type": "box", "lo": Vector3i(0, VoxelCodec.GRID / 32, 0), "hi": Vector3i(VoxelCodec.GRID, VoxelCodec.GRID / 32 + 2, VoxelCodec.GRID), "id": Elements.Id.SAND, "amount": 0})
		return ops
	return Scenarios.ops("Demo")

func _reset(ops: Array) -> void:
	_sim.tick = 0
	RenderingServer.call_on_render_thread(_sim._rt_experiment_reset.bind(ops))
	await _drain()

func _drain() -> void:
	_sim.request_layer_counts()
	await _sim.layer_counts_ready

func _state() -> Dictionary:
	_sim.request_readback(func(_bytes): pass)
	var bytes: PackedByteArray = await _sim.readback_ready
	var voxel_hash := _hash(bytes)
	_sim.request_velocity_readback()
	var air: PackedByteArray = await _sim.velocity_ready
	return {"voxels": voxel_hash, "air": _hash(air)}

func _hash(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()

func _case(workload: String, coalesce: bool, repeat_index: int) -> Dictionary:
	await _reset(_ops(workload))
	var painting := workload.contains("painting")
	var count := 0 if workload == "paused_painting" else 2
	var samples: Array[float] = []
	for frame in _warmup + _frames:
		var start := Time.get_ticks_usec()
		RenderingServer.call_on_render_thread(_sim._rt_experiment_step.bind(_sim.tick, count, frame if painting else -1, coalesce))
		_sim.tick += count
		await RenderingServer.frame_post_draw
		if frame >= _warmup:
			samples.append((Time.get_ticks_usec() - start) / 1000.0)
	await _drain()
	var state := await _state()
	var total := 0.0
	for sample in samples:
		total += sample
	samples.sort()
	print("CASE workload=%s variant=%s repeat=%d mean_ms=%.3f p95_ms=%.3f rebuilds=%d voxel_sha256=%s air_sha256=%s" % [workload, "coalesced" if coalesce else "baseline", repeat_index, total / samples.size(), samples[int(samples.size() * 0.95)], _sim.derived_rebuilds, state.voxels, state.air])
	return state

func _batch_case(batch: int) -> Dictionary:
	await _reset(Scenarios.ops("Forest fire"))
	for first_tick in range(0, 60, batch):
		_sim.request_ticks(batch)
		await RenderingServer.frame_post_draw
	await _drain()
	return await _state()
