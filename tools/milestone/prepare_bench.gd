extends SceneTree
## Current fixed-air/fixed-source simulation. Whole visible-frame timings.
## godot --path . --always-on-top --disable-vsync --resolution 1600x900 \
##   -s res://tools/milestone/prepare_bench.gd -- grid=128
var _sim: Node3D
var _frames := 120
const WARMUP := 30
var _failures := 0

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(180.0).timeout.connect(func(): push_error("Preparation benchmark timed out"); quit(1))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("frames="):
			_frames = int(arg.substr(7))
	call_deferred("_run")

func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	_sim = scene.get_node("SimVolume")
	_sim.listen_to_time_controller = false
	root.add_child(scene)
	current_scene = scene
	scene.get_node("Brush").set_process(false)
	var rig: Node3D = scene.get_node("CameraRig")
	rig.frame_position = Vector3(0.85, 0.65, 0.85) * rig.world_size
	rig.frame_box(false)
	for i in 20:
		await RenderingServer.frame_post_draw
	print("CONFIG grid=%d warmup=%d measured=%d ticks/frame=2 resolution=%s fixed_air=1" % [VoxelCodec.GRID, WARMUP, _frames, root.size])
	for repeat_index in 2:
		for workload in ["active", "frame_edit", "live_source", "paused_stroke"]:
			var results := []
			for deferred in ([false, true] if repeat_index == 0 else [true, false]):
				results.append(await _case(workload, deferred, repeat_index))
			var same: bool = results[0] == results[1]
			print("EQUIVALENCE workload=%s repeat=%d voxel_and_air=%s" % [workload, repeat_index, same])
			if not same:
				_failures += 1
	print("PREPARE_BENCH failures=%d" % _failures)
	scene.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _case(workload: String, deferred: bool, repeat_index: int) -> Dictionary:
	_sim.defer_render_preparation = deferred
	_sim.load_scenario("Demo")
	await _drain()
	var initial_preparations: int = _sim._rt_render_preparation_count
	var samples: Array[float] = []
	var measurement_start := 0
	for frame in WARMUP + _frames:
		if frame == WARMUP:
			await _drain()
			measurement_start = Time.get_ticks_usec()
		var start := Time.get_ticks_usec()
		var center := Vector3i(VoxelCodec.GRID / 2 + frame % 25 - 12, VoxelCodec.GRID * 3 / 4, VoxelCodec.GRID / 2)
		if workload == "live_source":
			_sim.set_live_emitter(center, 4, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 24.0, 812)
		if workload != "paused_stroke":
			_sim.request_ticks(2)
		if workload == "frame_edit":
			RenderingServer.call_on_render_thread(_sim._rt_paint.bind(center, 4, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 12345 + frame))
		elif workload == "paused_stroke":
			var centers: Array[Vector3i] = [center, center + Vector3i.RIGHT, center + Vector3i.RIGHT * 2, center + Vector3i.RIGHT * 3]
			RenderingServer.call_on_render_thread(_sim._rt_paint_stroke.bind(centers, 4, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 12345 + frame))
		await RenderingServer.frame_post_draw
		if frame >= WARMUP:
			samples.append((Time.get_ticks_usec() - start) / 1000.0)
	# Tiny synchronous counter read includes outstanding GPU tail work in the
	# aggregate mean. Full state readbacks/hashing occur after timing stops.
	await _drain()
	var drained_mean := (Time.get_ticks_usec() - measurement_start) / 1000.0 / _frames
	var rebuilds: int = _sim._rt_render_preparation_count - initial_preparations
	_sim.request_readback(func(_bytes): pass)
	var voxels: PackedByteArray = await _sim.readback_ready
	_sim.request_velocity_readback()
	var air: PackedByteArray = await _sim.velocity_ready
	var state := {"voxels": _hash(voxels), "air": _hash(air)}
	var mean := 0.0
	for sample in samples:
		mean += sample
	mean /= samples.size()
	samples.sort()
	print("CASE workload=%s deferred=%s repeat=%d frame_mean_ms=%.3f drained_mean_ms=%.3f p95_ms=%.3f rebuilds=%d voxels=%s air=%s" % [workload, deferred, repeat_index, mean, drained_mean, samples[int(samples.size() * 0.95)], rebuilds, state.voxels, state.air])
	return state

func _drain() -> void:
	_sim.request_layer_counts()
	await _sim.layer_counts_ready

func _hash(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()
