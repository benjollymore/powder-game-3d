extends SceneTree
## Cost of the thermal layer on the running-source frame: the same fixture
## and workload with RULE_NO_THERMAL set (conduction, phase change and
## ignition skipped; the layer is still carried, remapped and read by the
## air solver) versus clear, paired and alternated so drift affects both
## equally. Whole visible-frame wall intervals, 30 warm-up plus 120 measured
## frames per sample, medians reported. Not GPU device timestamps.
##
##   godot --path . --always-on-top --disable-vsync --resolution 1600x900 \
##     -s res://tools/milestone/thermal_bench.gd -- grid=128 output=/tmp/thermal-bench-128.json
##
## Quote numbers only from mains power with an idle GPU: the JSON records the
## macOS power mode (pmset powermode: 0 automatic, 1 low power, 2 high
## power) and the display refresh rate so a throttled run is recognisable.
var _sim: Node3D
var _frames := 120
var _repeats := 3
var _output := ""
## Cost variant applied to both sides of every pair (variant=name):
## baseline, early_out, skip_air, hydro_skip, air_sub2, interval2, all.
var _variant := "baseline"
const WARMUP := 30
const TICKS_PER_FRAME := 2

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(300.0).timeout.connect(func(): push_error("Thermal benchmark timed out"); quit(1))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("frames="):
			_frames = int(arg.substr(7))
		elif arg.begins_with("repeats="):
			_repeats = int(arg.substr(8))
		elif arg.begins_with("output="):
			_output = arg.substr(7)
		elif arg.begins_with("variant="):
			_variant = arg.substr(8)
	call_deferred("_run")

func _apply_variant() -> void:
	var all := _variant == "all"
	_sim.thermal_block_early_out = all or _variant == "early_out"
	_sim.thermal_skip_air_blocks = all or _variant == "skip_air"
	_sim.hydro_remap_skip_unchanged = all or _variant == "hydro_skip"
	_sim.air_heat_subsample = 2 if (all or _variant == "air_sub2") else 1
	_sim.thermal_interval = 2 if (all or _variant == "interval2") else 1

func _power_mode() -> Dictionary:
	var lines := []
	var code := OS.execute("pmset", ["-g"], lines, true)
	var mode := -1
	var source := "unknown"
	if code == 0:
		for line in "".join(lines).split("\n"):
			var stripped := line.strip_edges()
			if stripped.begins_with("powermode"):
				mode = int(stripped.trim_prefix("powermode").strip_edges())
			elif stripped.begins_with("Now drawing from"):
				source = stripped
	return {"pmset_powermode": mode, "pmset_source": source,
		"refresh_hz": DisplayServer.screen_get_refresh_rate(DisplayServer.window_get_current_screen())}

func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	_sim = scene.get_node("SimVolume")
	_sim.listen_to_time_controller = false
	root.add_child(scene)
	current_scene = scene
	scene.get_node("Brush").set_process(false)
	_apply_variant()
	var rig: Node3D = scene.get_node("CameraRig")
	rig.frame_position = Vector3(0.85, 0.65, 0.85) * rig.world_size
	rig.frame_box(false)
	for i in 20:
		await RenderingServer.frame_post_draw
	var report := {"grid": VoxelCodec.GRID, "warmup": WARMUP, "measured": _frames, "ticks_per_frame": TICKS_PER_FRAME, "variant": _variant,
		"resolution": [root.size.x, root.size.y], "thermal_speed": _sim.thermal_speed, "scenario": "Demo",
		"workload": "running Sand source, air on, hydro on", "environment": _power_mode(), "samples": []}
	print("CONFIG grid=%d variant=%s warmup=%d measured=%d ticks/frame=%d resolution=%s power=%s" % [VoxelCodec.GRID, _variant, WARMUP, _frames, TICKS_PER_FRAME, root.size, report.environment])
	for repeat_index in _repeats:
		for thermal in ([true, false] if repeat_index % 2 == 0 else [false, true]):
			var sample := await _case(thermal, repeat_index)
			report.samples.append(sample)
	# Paired medians: thermal on minus thermal off within each repeat.
	var deltas := []
	for repeat_index in _repeats:
		var on := 0.0
		var off := 0.0
		for sample in report.samples:
			if sample.repeat == repeat_index:
				if sample.thermal: on = sample.frame_median_ms
				else: off = sample.frame_median_ms
		deltas.append(on - off)
	report["paired_median_delta_ms"] = deltas
	print("THERMAL_BENCH grid=%d variant=%s paired_median_delta_ms=%s" % [VoxelCodec.GRID, _variant, deltas])
	if _output != "":
		var file := FileAccess.open(_output, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	scene.queue_free()
	for i in 3:
		await process_frame
	quit(0)

func _case(thermal: bool, repeat_index: int) -> Dictionary:
	_sim.rule_flags = 0 if thermal else _sim.RULE_NO_THERMAL
	_sim.load_scenario("Demo")
	await _drain()
	var samples: Array[float] = []
	var measurement_start := 0
	for frame in WARMUP + _frames:
		if frame == WARMUP:
			await _drain()
			measurement_start = Time.get_ticks_usec()
		var start := Time.get_ticks_usec()
		var center := Vector3i(VoxelCodec.GRID / 2 + frame % 25 - 12, VoxelCodec.GRID * 3 / 4, VoxelCodec.GRID / 2)
		_sim.set_live_emitter(center, 4, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 24.0, 812)
		_sim.request_ticks(TICKS_PER_FRAME)
		await RenderingServer.frame_post_draw
		if frame >= WARMUP:
			samples.append((Time.get_ticks_usec() - start) / 1000.0)
	await _drain()
	_sim.clear_live_emitter()
	var drained_mean := (Time.get_ticks_usec() - measurement_start) / 1000.0 / _frames
	var mean := 0.0
	for sample in samples:
		mean += sample
	mean /= samples.size()
	samples.sort()
	var result := {"thermal": thermal, "repeat": repeat_index, "frame_mean_ms": mean, "drained_mean_ms": drained_mean,
		"frame_median_ms": samples[samples.size() / 2], "p95_ms": samples[int(samples.size() * 0.95)]}
	print("CASE variant=%s thermal=%s repeat=%d frame_mean_ms=%.3f drained_mean_ms=%.3f median_ms=%.3f p95_ms=%.3f" % [_variant, thermal, repeat_index, mean, drained_mean, result.frame_median_ms, result.p95_ms])
	return result

func _drain() -> void:
	_sim.request_layer_counts()
	await _sim.layer_counts_ready
