extends SceneTree
signal done(result: Variant)
var _gpu: RefCounted
var _initial := PackedFloat32Array()
var _label: Label
var _n := 128
var _frames := 240
var _failures := 0
var _variant := "two-pass"
var _capture_prefix := "bench"
const WARMUP := 30
const DT := 1.0 / 60.0

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(180.0).timeout.connect(func(): push_error("Thermal benchmark timed out"); quit(1))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("thermal_grid="):
			_n = int(arg.substr(13))
		elif arg.begins_with("frames="):
			_frames = int(arg.substr(7))
	var panel := ColorRect.new()
	panel.color = Color(0.025, 0.045, 0.065)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)
	_label = Label.new()
	_label.position = Vector2(24, 24)
	root.add_child(_label)
	call_deferred("_run")

func _run() -> void:
	assert(_n in [128, 256])
	var count := _n * _n * _n
	_initial.resize(count / 2)
	_initial.fill(246.85) # synthetic PCM at360 K, full0.001kg cells
	var cold := PackedFloat32Array()
	cold.resize(count / 2)
	cold.fill(16.85) # same material at290 K
	_initial.append_array(cold)
	cold.clear()
	var ids := PackedInt32Array()
	ids.resize(count)
	ids.fill(0)
	var case := {"shape": [_n, _n, _n], "dx": 0.01, "stable_dt": 1000.0*1000.0*0.01*0.01/(6.0*10.0),
		"initial_energy": _initial, "material_ids": ids, "materials": [[1000, 10, 1000, 2000, 300, 100000, 26850, 0]]}
	_gpu = load("res://tools/feasibility/thermal_gpu/thermal_gpu.gd").new()
	RenderingServer.call_on_render_thread(_rt_initialize.bind(case))
	await done
	print("THERMAL_BENCH_CONFIG n=%d resolution=%s warmup=%d frames=%d dt=%.9f logical_MiB=%d" % [_n, root.size, WARMUP, _frames, DT, count * 36 / 1048576])
	for repeat_index in 2:
		for steps in ([0, 1, 4] if repeat_index == 0 else [4, 1, 0]):
			await _case(steps, repeat_index)
	RenderingServer.call_on_render_thread(_rt_close)
	await done
	print("THERMAL_BENCH failures=%d" % _failures)
	quit(1 if _failures else 0)

func _case(steps: int, repeat_index: int) -> void:
	_label.text = "Isolated stationary thermal GPU benchmark (%s)\n%d³ cells · %d steps/frame · repeat%d\nFP32 energy + latent phase · insulated boundary\nNo production simulation or fluid coupling" % [_variant, _n, steps, repeat_index]
	RenderingServer.call_on_render_thread(_rt_reset)
	await done
	var samples: Array[float] = []
	var start := 0
	for frame in WARMUP + _frames:
		if frame == WARMUP:
			RenderingServer.call_on_render_thread(_rt_drain)
			await done
			start = Time.get_ticks_usec()
		var frame_start := Time.get_ticks_usec()
		if steps > 0:
			RenderingServer.call_on_render_thread(_gpu.advance.bind(steps, DT))
		await RenderingServer.frame_post_draw
		if frame >= WARMUP:
			samples.append((Time.get_ticks_usec()-frame_start)/1000.0)
	RenderingServer.call_on_render_thread(_rt_drain)
	await done
	var drained_mean := (Time.get_ticks_usec()-start)/1000.0/_frames
	RenderingServer.call_on_render_thread(_rt_probe)
	var values: PackedFloat32Array = await done
	var changed := values[0] < _initial[0] and values[1] > _initial[-1]
	if steps > 0 and not changed:
		_failures += 1
		push_error("Thermal interface did not exchange energy")
	if steps == 0 and (values[0] != _initial[0] or values[1] != _initial[-1]):
		_failures += 1
		push_error("Idle case changed energy")
	samples.sort()
	print("CASE variant=%s n=%d steps_per_frame=%d repeat=%d drained_mean_ms=%.6f frame_p95_ms=%.6f ticks=%d interface_energy_J=%s" % [_variant, _n, steps, repeat_index, drained_mean, samples[int(samples.size()*.95)], _gpu.ticks, values])
	if repeat_index == 0 and steps == 1:
		root.get_texture().get_image().save_png("res://docs/milestone/evidence-thermal-gpu/%s-%d.png" % [_capture_prefix, _n])

func _rt_initialize(case: Dictionary) -> void:
	_gpu.initialize(case)
	_gpu.drain()
	done.emit.call_deferred(null)

func _rt_reset() -> void:
	_gpu.reset(_initial)
	_gpu.drain()
	done.emit.call_deferred(null)

func _rt_drain() -> void:
	_gpu.drain()
	done.emit.call_deferred(null)

func _rt_probe() -> void:
	var cold_index := _n*_n*(_n/2)+_n*(_n/2)+_n/2
	done.emit.call_deferred(_gpu.probe(PackedInt32Array([cold_index-_n*_n, cold_index])))

func _rt_close() -> void:
	_gpu.close()
	done.emit.call_deferred(null)
