extends "res://tools/feasibility/thermal_gpu/bench.gd"
## Same-process allocation-order A/B; first fused kernel remains unchanged.
func _run() -> void:
	assert(_n in [128,256])
	var count := _n*_n*_n
	_initial.resize(count/2)
	_initial.fill(246.85)
	var cold := PackedFloat32Array()
	cold.resize(count/2)
	cold.fill(16.85)
	_initial.append_array(cold)
	cold.clear()
	var ids := PackedInt32Array()
	ids.resize(count)
	ids.fill(0)
	var case := {"shape":[_n,_n,_n],"dx":0.01,"stable_dt":1000.0*1000.0*0.01*0.01/(6.0*10.0),
		"initial_energy":_initial,"material_ids":ids,"materials":[[1000,10,1000,2000,300,100000,26850,0]]}
	for repeat_index in 2:
		for variant in (["fused","reuse"] if repeat_index==0 else ["reuse","fused"]):
			_variant=variant
			_capture_prefix="reuse-"+variant
			var script := "fused_gpu.gd" if variant=="fused" else "reuse_gpu.gd"
			_gpu=load("res://tools/feasibility/thermal_gpu/"+script).new()
			RenderingServer.call_on_render_thread(_rt_initialize.bind(case))
			await done
			print("THERMAL_COMPARE_CONFIG variant=%s n=%d logical_MiB=%d diagnostics_allocated=%s" % [variant,_n,count*12/1048576,_gpu._states.is_valid()])
			for steps in ([0,1,4] if repeat_index==0 else [4,1,0]):
				await _case(steps,repeat_index)
			RenderingServer.call_on_render_thread(_rt_close)
			await done
	print("THERMAL_COMPARE_BENCH failures=%d" % _failures)
	quit(1 if _failures else 0)
