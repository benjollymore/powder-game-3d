extends SceneTree
func _initialize() -> void:
	var gpu: RefCounted=load("res://tools/feasibility/mechanics_gpu/gpu.gd").new();var failures:=0
	for dt in [-1.0,0.0,INF,NAN,1e-100,1e40]:
		if gpu.advance(1,dt):failures+=1
	if gpu.advance(-1,.01):failures+=1
	for name in ["validate","force","plane_admit","commit","snapshot_grid"]:
		var file: RDShaderFile=load("res://tools/feasibility/mechanics_gpu/"+name+".glsl")
		if not file.get_spirv().compile_error_compute.is_empty():failures+=1;push_error(file.get_spirv().compile_error_compute)
	print("MECHANICS_ADMISSION checks=12 failures=%d"%failures);quit(1 if failures else 0)
