extends SceneTree
func _initialize() -> void:
	var gpu: RefCounted=load("res://tools/feasibility/momentum_gpu/gpu.gd").new()
	var failures:=0
	for dt in [-1.0,0.0,INF,NAN,1e-100,1e40]:
		if gpu.advance(1,dt):failures+=1
	if gpu.advance(-1,.01):failures+=1
	for name in ["validate","p2g","g2p","commit"]:
		var file: RDShaderFile=load("res://tools/feasibility/momentum_gpu/"+name+".glsl")
		if not file.get_spirv().compile_error_compute.is_empty():
			failures+=1;push_error(file.get_spirv().compile_error_compute)
	print("MOMENTUM_MOTION_ADMISSION checks=11 failures=%d"%failures)
	quit(1 if failures else 0)
