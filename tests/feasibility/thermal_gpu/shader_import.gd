extends SceneTree
func _initialize() -> void:
	var failures := 0
	for name in ["face_flux", "gather_energy", "fused_heat", "decode_state", "face_audit", "reuse_heat", "reuse_audit", "decode_temperature", "cached_heat", "cached_audit"]:
		var shader: RDShaderFile = load("res://tools/feasibility/thermal_gpu/" + name + ".glsl")
		var error := shader.get_spirv().compile_error_compute
		if not error.is_empty():
			failures += 1
			push_error(name + ": " + error)
	print("THERMAL_SHADER_IMPORT checks=10 failures=%d" % failures)
	quit(1 if failures else 0)
