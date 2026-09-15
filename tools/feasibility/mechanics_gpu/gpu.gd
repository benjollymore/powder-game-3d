extends "res://tools/feasibility/momentum_gpu/gpu.gd"
## Isolated candidate mechanics. Committed ledger and last-attempt node records differ.
var _node_count:=0
var _audit_bytes:=0

func initialize(case: Dictionary) -> void:
	rd=RenderingServer.get_rendering_device()
	shape=Vector3i(case.shape[0],case.shape[1],case.shape[2]);count=case.initial_particles.size();dx=case.dx;apic=case.method=="apic"
	assert(count>0 and shape.x>=3 and shape.y>=3 and shape.z>=3 and dx>0.0 and is_finite(dx))
	assert(case.method in ["pic","apic"])
	_node_count=shape.x*shape.y*shape.z;_audit_bytes=(44+_node_count*28)*4
	var values:=PackedFloat32Array()
	for p in case.initial_particles:values.append_array(PackedFloat32Array(p))
	var gravity: Array=case.get("gravity",[0.,0.,0.])
	var plane: Variant=case.get("plane",null)
	var origin: Array=case.get("origin",[0.,0.,0.])
	var config:=PackedFloat32Array([gravity[0],gravity[1],gravity[2],0.,float(plane) if plane!=null else 0.,1. if plane!=null else 0.,0.,0.,origin[0],origin[1],origin[2],0.]).to_byte_array()
	_buffers=[rd.storage_buffer_create(count*80,values.to_byte_array()),rd.storage_buffer_create(count*80),rd.storage_buffer_create(_node_count*16),rd.storage_buffer_create(count*4),rd.storage_buffer_create(32),rd.storage_buffer_create(config.size(),config),rd.storage_buffer_create(_audit_bytes)]
	var paths: Array[String]=["mechanics_gpu/validate","momentum_gpu/p2g","mechanics_gpu/force","momentum_gpu/g2p","mechanics_gpu/plane_admit","mechanics_gpu/commit","mechanics_gpu/snapshot_grid"]
	for stage in paths.size():
		var file: RDShaderFile=load("res://tools/feasibility/"+paths[stage]+".glsl")
		assert(file.get_spirv().compile_error_compute.is_empty())
		var shader:=rd.shader_create_from_spirv(file.get_spirv());_shaders.append(shader);_pipelines.append(rd.compute_pipeline_create(shader))
		var uniforms: Array[RDUniform]=[]
		for i in (5 if stage in [1,3,6] else 7):
			var u:=RDUniform.new();u.uniform_type=RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER;u.binding=i;u.add_id(_buffers[i]);uniforms.append(u)
		_sets.append(rd.uniform_set_create(uniforms,shader,0))
	reset(values)

func reset(values: PackedFloat32Array) -> void:
	rd.buffer_clear(_buffers[6],0,_audit_bytes)
	super.reset(values)

func advance(steps: int,dt: float) -> bool:
	last_error="";var encoded:=PackedFloat32Array([dt])[0]
	if steps<0 or not is_finite(dt) or dt<=0 or not is_finite(encoded) or encoded<=0:
		last_error="Positive finite FP32 timestep and nonnegative count required";return false
	var cl:=rd.compute_list_begin()
	for i in steps:
		for stage in [1,2,3,4,5]:_dispatch(cl,stage,encoded);rd.compute_list_add_barrier(cl)
	rd.compute_list_end();return true

func snapshot() -> Dictionary:
	# The working grid may contain uncommitted forces. Always rebuild this
	# authoritative diagnostic from current particles, even after step rejection.
	var cl:=rd.compute_list_begin();_dispatch(cl,6,0.0);rd.compute_list_end()
	return {"particles":rd.buffer_get_data(_buffers[0]),"grid":rd.buffer_get_data(_buffers[2]).to_float32_array(),"status":rd.buffer_get_data(_buffers[4]).to_int32_array(),"audit":rd.buffer_get_data(_buffers[6])}

func _dispatch(cl: int,stage: int,dt: float) -> void:
	rd.compute_list_bind_compute_pipeline(cl,_pipelines[stage]);rd.compute_list_bind_uniform_set(cl,_sets[stage],0)
	var push:=PackedInt32Array([shape.x,shape.y,shape.z,count]).to_byte_array();push.append_array(PackedFloat32Array([dx,dt,1.0 if apic else 0.0,0.0]).to_byte_array())
	rd.compute_list_set_push_constant(cl,push,push.size())
	var groups:=1 if stage in [0,5] else ceili((_node_count if stage in [1,2,6] else count)/64.0)
	rd.compute_list_dispatch(cl,groups,1,1)
