extends RefCounted
## Isolated FP32 stationary conduction. Every method runs on the render thread.
## The caller supplies CPU-validated full-cell geometry/materials and the exact
## explicit stability bound from thermal_reference.Grid (or homogeneous formula).
var rd: RenderingDevice
var shape: Vector3i
var dx: float
var stable_dt: float
var last_error := ""
var ticks := 0
var _current := 0
var _energy: Array[RID] = []
var _flux := RID()
var _states := RID()
var _ids := RID()
var _materials := RID()
var _shaders: Array[RID] = []
var _pipelines: Array[RID] = []
var _flux_sets: Array[RID] = []
var _gather_sets: Array[RID] = []

func initialize(case: Dictionary) -> void:
	rd = RenderingServer.get_rendering_device()
	shape = Vector3i(case.shape[0], case.shape[1], case.shape[2])
	dx = case.dx
	stable_dt = case.stable_dt
	var n := shape.x * shape.y * shape.z
	var initial := PackedFloat32Array(case.initial_energy).to_byte_array()
	assert(initial.size() == n * 4 and case.material_ids.size() == n)
	_energy = [rd.storage_buffer_create(initial.size(), initial), rd.storage_buffer_create(initial.size())]
	_flux = rd.storage_buffer_create(n * 16)
	_states = rd.storage_buffer_create(n * 8)
	_ids = rd.storage_buffer_create(n * 4, PackedInt32Array(case.material_ids).to_byte_array())
	var coefficients := PackedFloat32Array()
	for material in case.materials:
		coefficients.append_array(PackedFloat32Array(material))
	_materials = rd.storage_buffer_create(coefficients.size() * 4, coefficients.to_byte_array())
	for path in ["face_flux", "gather_energy"]:
		var file: RDShaderFile = load("res://tools/feasibility/thermal_gpu/%s.glsl" % path)
		var shader := rd.shader_create_from_spirv(file.get_spirv())
		_shaders.append(shader)
		_pipelines.append(rd.compute_pipeline_create(shader))
	for i in 2:
		_flux_sets.append(rd.uniform_set_create([_buffer(0, _energy[i]), _buffer(1, _materials), _buffer(2, _ids), _buffer(3, _flux), _buffer(4, _states)], _shaders[0], 0))
		_gather_sets.append(rd.uniform_set_create([_buffer(0, _energy[i]), _buffer(1, _flux), _buffer(2, _energy[1-i])], _shaders[1], 0))

func advance(count: int, dt: float) -> bool:
	last_error = ""
	var encoded_dt := PackedFloat32Array([dt])[0]
	if count < 0 or not is_finite(dt) or dt <= 0.0 or not is_finite(encoded_dt) or encoded_dt <= 0.0:
		last_error = "Count must be nonnegative and dt positive, finite and representable in FP32"
		return false
	# Check the value actually submitted, not just its binary64 source.
	if encoded_dt > stable_dt:
		last_error = "FP32 time step exceeds the supplied conservative explicit bound"
		return false
	var cl := rd.compute_list_begin()
	for i in count:
		_dispatch(cl, 0, _flux_sets[_current], encoded_dt)
		rd.compute_list_add_barrier(cl)
		_dispatch(cl, 1, _gather_sets[_current], encoded_dt)
		rd.compute_list_add_barrier(cl)
		_current = 1 - _current
	rd.compute_list_end()
	ticks += count
	return true

func snapshot() -> Dictionary:
	# Refresh diagnostic temperature/fraction for the latest energy. This
	# zero-time face pass and full readbacks are excluded from dispatch timing.
	var cl := rd.compute_list_begin()
	_dispatch(cl, 0, _flux_sets[_current], 0.0)
	rd.compute_list_end()
	return {"energy": rd.buffer_get_data(_energy[_current]).to_float32_array(), "state": rd.buffer_get_data(_states).to_float32_array(), "ticks": ticks}

func drain() -> void:
	# Synchronize queued GPU work with one energy scalar, not a full-volume copy.
	rd.buffer_get_data(_energy[_current], 0, 4)

func close() -> void:
	for rid in _flux_sets + _gather_sets + _pipelines + _shaders + _energy + [_flux, _states, _ids, _materials]:
		if rid.is_valid():
			rd.free_rid(rid)

func _dispatch(cl: int, kernel: int, uniform_set: RID, dt: float) -> void:
	rd.compute_list_bind_compute_pipeline(cl, _pipelines[kernel])
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	var push := PackedInt32Array([shape.x, shape.y, shape.z, 0]).to_byte_array()
	push.append_array(PackedFloat32Array([dx, dt, 0.0, 0.0]).to_byte_array())
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, ceili(shape.x / 8.0), ceili(shape.y / 4.0), ceili(shape.z / 4.0))

func _buffer(binding: int, rid: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(rid)
	return uniform

func reset(initial_energy: PackedFloat32Array) -> void:
	assert(initial_energy.size() == shape.x * shape.y * shape.z)
	rd.buffer_update(_energy[0], 0, initial_energy.size() * 4, initial_energy.to_byte_array())
	_current = 0
	ticks = 0

func probe(indices: PackedInt32Array) -> PackedFloat32Array:
	var values := PackedFloat32Array()
	for index in indices:
		values.append(rd.buffer_get_data(_energy[_current], index * 4, 4).decode_float(0))
	return values
