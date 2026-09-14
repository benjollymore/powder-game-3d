extends SceneTree
## Invalid-step admission is pure and must not require a RenderingDevice.
func _initialize() -> void:
	var failures := 0
	var checks := 0
	for path in ["thermal_gpu.gd", "fused_gpu.gd"]:
		var gpu: RefCounted = load("res://tools/feasibility/thermal_gpu/" + path).new()
		gpu.stable_dt = 0.1
		for pair in [[1, -1.0], [1, 0.0], [1, INF], [1, NAN], [1, 1e-100], [1, 1e40], [-1, 0.05], [1, 0.2], [1, 0.1]]:
			checks += 1
			if gpu.advance(pair[0], pair[1]) or gpu.ticks != 0 or gpu.last_error.is_empty():
				failures += 1
				push_error(path + ": invalid or upward-rounded step was accepted")
	# 0.1 binary64 is within the host bound, but its FP32 representation is
	# larger. The last case proves admission checks actual submitted arithmetic.
	print("THERMAL_ADMISSION checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
