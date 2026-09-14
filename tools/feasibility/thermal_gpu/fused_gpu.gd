extends "res://tools/feasibility/thermal_gpu/thermal_gpu.gd"
## Fused experiment:12B/cell resident; diagnostic8B/cell allocated only on inspection.
## The two-pass reference remains unchanged in thermal_gpu.gd.
var no_contraction_decorations := 0

func initialize(case: Dictionary) -> void:
	rd = RenderingServer.get_rendering_device()
	shape = Vector3i(case.shape[0], case.shape[1], case.shape[2])
	dx = case.dx
	stable_dt = case.stable_dt
	var n := shape.x * shape.y * shape.z
	var initial := PackedFloat32Array(case.initial_energy).to_byte_array()
	assert(initial.size() == n * 4 and case.material_ids.size() == n)
	_energy = [rd.storage_buffer_create(initial.size(), initial), rd.storage_buffer_create(initial.size())]
	_ids = rd.storage_buffer_create(n * 4, PackedInt32Array(case.material_ids).to_byte_array())
	var coefficients := PackedFloat32Array()
	for material in case.materials:
		coefficients.append_array(PackedFloat32Array(material))
	_materials = rd.storage_buffer_create(coefficients.size()*4, coefficients.to_byte_array())
	for path in ["fused_heat", "decode_state"]:
		var file: RDShaderFile = load("res://tools/feasibility/thermal_gpu/%s.glsl" % path)
		var spirv := file.get_spirv()
		if path == "fused_heat":
			no_contraction_decorations = _count_no_contraction(spirv.bytecode_compute)
		var shader := rd.shader_create_from_spirv(spirv)
		_shaders.append(shader)
		_pipelines.append(rd.compute_pipeline_create(shader))
	for i in 2:
		_flux_sets.append(rd.uniform_set_create([_buffer(0,_energy[i]),_buffer(1,_materials),_buffer(2,_ids),_buffer(3,_energy[1-i])],_shaders[0],0))

func advance(count: int, dt: float) -> bool:
	last_error = ""
	var encoded_dt := PackedFloat32Array([dt])[0]
	if count < 0 or not is_finite(dt) or dt <= 0.0 or not is_finite(encoded_dt) or encoded_dt <= 0.0:
		last_error = "Count must be nonnegative and dt positive, finite and representable in FP32"
		return false
	if encoded_dt > stable_dt:
		last_error = "FP32 time step exceeds the supplied conservative explicit bound"
		return false
	var cl := rd.compute_list_begin()
	for i in count:
		_dispatch(cl,0,_flux_sets[_current],encoded_dt)
		rd.compute_list_add_barrier(cl)
		_current = 1 - _current
	rd.compute_list_end()
	ticks += count
	return true

func snapshot() -> Dictionary:
	if not _states.is_valid():
		_states = rd.storage_buffer_create(shape.x*shape.y*shape.z*8)
		for i in 2:
			_gather_sets.append(rd.uniform_set_create([_buffer(0,_energy[i]),_buffer(1,_materials),_buffer(2,_ids),_buffer(3,_states)],_shaders[1],0))
	var cl := rd.compute_list_begin()
	_dispatch(cl,1,_gather_sets[_current],0.0)
	rd.compute_list_end()
	return {"energy":rd.buffer_get_data(_energy[_current]).to_float32_array(),"state":rd.buffer_get_data(_states).to_float32_array(),"ticks":ticks}

func audit_faces(dt: float) -> PackedByteArray:
	var file: RDShaderFile = load("res://tools/feasibility/thermal_gpu/face_audit.glsl")
	var shader := rd.shader_create_from_spirv(file.get_spirv())
	var pipeline := rd.compute_pipeline_create(shader)
	var buffer := rd.storage_buffer_create(shape.x*shape.y*shape.z*32)
	var uniform_set := rd.uniform_set_create([_buffer(0,_energy[_current]),_buffer(1,_materials),_buffer(2,_ids),_buffer(3,buffer)],shader,0)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl,pipeline)
	rd.compute_list_bind_uniform_set(cl,uniform_set,0)
	var push := PackedInt32Array([shape.x,shape.y,shape.z,0]).to_byte_array()
	push.append_array(PackedFloat32Array([dx,dt,0,0]).to_byte_array())
	rd.compute_list_set_push_constant(cl,push,push.size())
	rd.compute_list_dispatch(cl,ceili(shape.x/8.0),ceili(shape.y/4.0),ceili(shape.z/4.0))
	rd.compute_list_end()
	var bytes := rd.buffer_get_data(buffer)
	for rid in [uniform_set,pipeline,shader,buffer]:
		rd.free_rid(rid)
	return bytes

static func _count_no_contraction(bytes: PackedByteArray) -> int:
	var words := bytes.to_int32_array()
	var offset := 5 # SPIR-V header
	var count := 0
	while offset < words.size():
		var instruction := words[offset]
		var size := (instruction >> 16) & 0xFFFF
		assert(size > 0)
		if (instruction & 0xFFFF) == 71 and size >= 3 and words[offset+2] == 42:
			count += 1 # OpDecorate / NoContraction
		offset += size
	return count
