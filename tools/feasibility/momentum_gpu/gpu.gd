extends RefCounted
## All methods run on the render thread. Tiny deterministic gather experiment.
var rd: RenderingDevice
var shape := Vector3i.ZERO
var count := 0
var dx := 0.1
var apic := true
var last_error := ""
var _buffers: Array[RID] = []
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _sets: Array[RID] = []

func initialize(case: Dictionary) -> void:
	rd=RenderingServer.get_rendering_device()
	shape=Vector3i(case.shape[0],case.shape[1],case.shape[2])
	count=case.initial_particles.size();dx=case.dx;apic=case.method=="apic"
	assert(count>0 and shape.x>=3 and shape.y>=3 and shape.z>=3)
	assert(case.method in ["pic","apic"] and is_finite(dx) and dx>0.0 and is_finite(PackedFloat32Array([dx])[0]) and PackedFloat32Array([dx])[0]>0.0)
	var values := PackedFloat32Array()
	for p in case.initial_particles:values.append_array(PackedFloat32Array(p))
	_buffers=[rd.storage_buffer_create(count*80,values.to_byte_array()),rd.storage_buffer_create(count*80),rd.storage_buffer_create(shape.x*shape.y*shape.z*16),rd.storage_buffer_create(count*4),rd.storage_buffer_create(32)]
	for name in ["validate","p2g","g2p","commit"]:
		var file: RDShaderFile=load("res://tools/feasibility/momentum_gpu/"+name+".glsl")
		assert(file.get_spirv().compile_error_compute.is_empty())
		var shader:=rd.shader_create_from_spirv(file.get_spirv())
		_shaders.append(shader);_pipelines.append(rd.compute_pipeline_create(shader))
		var uniforms: Array[RDUniform]=[]
		for i in _buffers.size():
			var u:=RDUniform.new();u.uniform_type=RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER;u.binding=i;u.add_id(_buffers[i]);uniforms.append(u)
		_sets.append(rd.uniform_set_create(uniforms,shader,0))
	reset(values)

func reset(values: PackedFloat32Array) -> void:
	assert(values.size()==count*20)
	rd.buffer_update(_buffers[0],0,values.size()*4,values.to_byte_array())
	rd.buffer_clear(_buffers[4],0,32)
	# Invalid initial support halts P2G, so never expose a previous run's grid.
	rd.buffer_clear(_buffers[2],0,shape.x*shape.y*shape.z*16)
	var cl:=rd.compute_list_begin();_dispatch(cl,0,0.0);rd.compute_list_end()

func advance(steps: int, dt: float) -> bool:
	last_error=""
	var encoded:=PackedFloat32Array([dt])[0]
	if steps<0 or not is_finite(dt) or dt<=0 or not is_finite(encoded) or encoded<=0:
		last_error="Positive finite FP32 timestep and nonnegative count required"
		return false
	var cl:=rd.compute_list_begin()
	for i in steps:
		for stage in [1,2,3]:
			_dispatch(cl,stage,encoded);rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	return true # Submission accepted; inspect GPU status for completed/admitted steps.

func snapshot() -> Dictionary:
	var cl:=rd.compute_list_begin();_dispatch(cl,1,0.0);rd.compute_list_end()
	return {"particles":rd.buffer_get_data(_buffers[0]),"grid":rd.buffer_get_data(_buffers[2]).to_float32_array(),"status":rd.buffer_get_data(_buffers[4]).to_int32_array()}

func _dispatch(cl: int, stage: int, dt: float) -> void:
	rd.compute_list_bind_compute_pipeline(cl,_pipelines[stage]);rd.compute_list_bind_uniform_set(cl,_sets[stage],0)
	var push:=PackedInt32Array([shape.x,shape.y,shape.z,count]).to_byte_array()
	push.append_array(PackedFloat32Array([dx,dt,1.0 if apic else 0.0,0.0]).to_byte_array())
	rd.compute_list_set_push_constant(cl,push,push.size())
	var groups:=1 if stage in [0,3] else ceili((shape.x*shape.y*shape.z if stage==1 else count)/64.0)
	rd.compute_list_dispatch(cl,groups,1,1)

func close() -> void:
	for rid in _sets+_pipelines+_shaders+_buffers:rd.free_rid(rid)
