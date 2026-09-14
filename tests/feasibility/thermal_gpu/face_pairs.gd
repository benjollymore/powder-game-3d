extends SceneTree
signal pairs_ready(result: Dictionary)
var _gpu: RefCounted
var _failures := 0
var _checks := 0

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(90.0).timeout.connect(func(): push_error("Face audit timed out"); quit(1))
	call_deferred("_run")

func _run() -> void:
	var fixtures: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://tests/feasibility/thermal_gpu/cases.json"))
	for case in fixtures.cases:
		if case.name not in ["hotspot_3d", "interface_3d", "batch_phase", "varied_materials_3d"]:
			continue
		_gpu = load("res://tools/feasibility/thermal_gpu/fused_gpu.gd").new()
		RenderingServer.call_on_render_thread(_rt_audit.bind(case))
		var result: Dictionary = await pairs_ready
		_check(result.decorations > 0, "%s SPIR-V retains NoContraction decorations (%d)" % [case.name, result.decorations])
		_check(result.stages[0].nonzero > 0, "%s audit includes nonzero heat flow" % case.name)
		for stage in result.stages:
			_check(stage.faces > 0 and stage.mismatches == 0, "%s tick%d canonical face pairs: %d comparisons, %d bit mismatches" % [case.name, stage.tick, stage.faces, stage.mismatches])
		print("FACE_METRIC name=%s stages=%s" % [case.name, result.stages])
		RenderingServer.call_on_render_thread(_gpu.close)
		await process_frame
	print("FACE_PAIRS checks=%d failures=%d" % [_checks, _failures])
	quit(1 if _failures else 0)

func _rt_audit(case: Dictionary) -> void:
	_gpu.initialize(case)
	var result := {"decorations": _gpu.no_contraction_decorations, "stages": []}
	for steps in [0, 1000]:
		if steps > 0:
			assert(_gpu.advance(steps, case.dt))
		var bytes: PackedByteArray = _gpu.audit_faces(case.dt)
		var shape: Vector3i = _gpu.shape
		var faces := 0
		var mismatches := 0
		var nonzero := 0
		var strides := [1, shape.x, shape.x*shape.y]
		for z in shape.z:
			for y in shape.y:
				for x in shape.x:
					var i := x+shape.x*(y+shape.y*z)
					var p := Vector3i(x,y,z)
					for axis in 3:
						if p[axis]+1 >= shape[axis]:
							continue
						var a := bytes.decode_u32(i*32+axis*4)
						var b := bytes.decode_u32((i+strides[axis])*32+16+axis*4)
						faces += 1
						if a != b:
							mismatches += 1
						if (a & 0x7FFFFFFF) != 0:
							nonzero += 1
		result.stages.append({"tick": _gpu.ticks, "faces": faces, "mismatches": mismatches, "nonzero": nonzero})
	pairs_ready.emit.call_deferred(result)

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if ok:
		print("ok: " + message)
	else:
		_failures += 1
		push_error(message)
