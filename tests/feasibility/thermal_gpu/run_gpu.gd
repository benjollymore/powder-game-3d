extends SceneTree
signal ready_result(result: Dictionary)
var _gpu: RefCounted
var _checks := 0
var _failures := 0
var _label: Label
var _results := {"cases": [], "batch_equal": [], "checks": 0, "failures": 0}
const GPU_PATH := "res://tools/feasibility/thermal_gpu/thermal_gpu.gd"

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(180.0).timeout.connect(func(): push_error("Thermal GPU experiment timed out"); quit(1))
	var panel := ColorRect.new()
	panel.color = Color(0.035, 0.055, 0.075)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)
	_label = Label.new()
	_label.position = Vector2(20, 20)
	_label.text = "Isolated GPU thermal feasibility"
	root.add_child(_label)
	call_deferred("_run")

func _run() -> void:
	for i in 4:
		await RenderingServer.frame_post_draw
	var fixtures: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/feasibility/thermal_gpu/cases.json"))
	for case in fixtures.cases:
		_label.text = "Isolated GPU thermal feasibility\n" + case.name
		_gpu = load(GPU_PATH).new()
		RenderingServer.call_on_render_thread(_rt_initialize.bind(case))
		var initial: Dictionary = await ready_result
		var result := {"name": case.name, "initial": initial, "snapshots": []}
		var tick := 0
		for expected in case.snapshots:
			RenderingServer.call_on_render_thread(_rt_advance_snapshot.bind(int(expected.tick)-tick, case.dt))
			var state: Dictionary = await ready_result
			_check(state.accepted, "%s accepts stable step at tick%d" % [case.name, expected.tick])
			result.snapshots.append(state)
			tick = expected.tick
		# Rejected steps must not change energy or the submitted tick count.
		var before: Dictionary = result.snapshots[-1]
		for invalid_dt in [-1.0, 0.0, INF, NAN, case.stable_dt * 2.0]:
			RenderingServer.call_on_render_thread(_rt_advance_snapshot.bind(1, invalid_dt))
			var rejected: Dictionary = await ready_result
			_check(not rejected.accepted and rejected.energy == before.energy and rejected.ticks == before.ticks, "%s invalid dt is rejected without mutation" % case.name)
		_results.cases.append(result)
		if case.name == "batch_phase":
			for schedule in [[1], [3], [7, 2, 5, 1, 9]]:
				RenderingServer.call_on_render_thread(_gpu.close)
				_gpu = load(GPU_PATH).new()
				RenderingServer.call_on_render_thread(_rt_initialize.bind(case))
				await ready_result
				var advanced := 0
				var part := 0
				while advanced < case.steps:
					var count := mini(schedule[part % schedule.size()], int(case.steps)-advanced)
					RenderingServer.call_on_render_thread(_gpu.advance.bind(count, case.dt))
					advanced += count
					part += 1
				RenderingServer.call_on_render_thread(_rt_snapshot)
				var grouped: Dictionary = await ready_result
				var equal: bool = grouped.energy == before.energy and grouped.state == before.state
				_check(equal, "thermal batches%s preserve exact energy and state bytes" % str(schedule))
				_results.batch_equal.append(equal)
		RenderingServer.call_on_render_thread(_gpu.close)
		await process_frame
	_results.checks = _checks
	_results.failures = _failures
	_results.engine = Engine.get_version_info().string
	FileAccess.open("res://docs/milestone/evidence-thermal-gpu/results.json", FileAccess.WRITE).store_string(JSON.stringify(_results, "  ")+"\n")
	print("THERMAL_GPU checks=%d failures=%d" % [_checks, _failures])
	quit(1 if _failures else 0)

func _rt_initialize(case: Dictionary) -> void:
	_gpu.initialize(case)
	ready_result.emit.call_deferred(_serializable(_gpu.snapshot()))

func _rt_advance_snapshot(count: int, dt: float) -> void:
	var accepted: bool = _gpu.advance(count, dt)
	var state: Dictionary = _serializable(_gpu.snapshot())
	state.accepted = accepted
	state.error = _gpu.last_error
	ready_result.emit.call_deferred(state)

func _rt_snapshot() -> void:
	ready_result.emit.call_deferred(_serializable(_gpu.snapshot()))

func _serializable(state: Dictionary) -> Dictionary:
	return {"energy": Array(state.energy), "state": Array(state.state), "ticks": state.ticks}

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if ok:
		print("ok: " + message)
	else:
		_failures += 1
		push_error(message)
