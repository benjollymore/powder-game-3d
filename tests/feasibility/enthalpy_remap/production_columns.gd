extends SceneTree
signal finished(result: Dictionary)
const GRID := 256
var _checks := 0
var _failures := 0

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(60).timeout.connect(func(): push_error("Production hydro comparison timed out"); quit(1))
	call_deferred("_run")

func _run() -> void:
	var cases: Array = JSON.parse_string(FileAccess.get_file_as_string("res://tests/feasibility/enthalpy_remap/columns.json"))
	RenderingServer.call_on_render_thread(_rt_compare.bind(cases))
	var result: Dictionary = await finished
	for row in result.rows:
		_check(row.amount_equal, "column%d exact amount target (%d cells)" % [row.index,row.count])
		_check(row.id_equal, "column%d empty cells normalize to air" % row.index)
		_check(row.mass_equal, "column%d integer mass preserved" % row.index)
	print("PRODUCTION_COLUMN_REMAP checks=%d failures=%d" % [_checks,_failures])
	quit(1 if _failures else 0)

func _rt_compare(cases: Array) -> void:
	var rd := RenderingServer.get_rendering_device()
	var bytes := PackedByteArray()
	bytes.resize(GRID*GRID*GRID*4)
	for x in cases.size():
		for y in cases[x].amounts.size():
			var offset: int = (x+GRID*y)*4
			bytes[offset] = Elements.Id.WATER
			bytes[offset+1] = (17+y)%256
			bytes[offset+2] = int(cases[x].amounts[y])
	var format := RDTextureFormat.new()
	format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	format.width=GRID;format.height=GRID;format.depth=GRID
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var texture := rd.texture_create(format,RDTextureView.new(),[bytes])
	var properties := Elements.property_bytes()
	var elements := rd.storage_buffer_create(properties.size(),properties)
	var file: RDShaderFile = load("res://shaders/compute/hydro.glsl")
	var shader := rd.shader_create_from_spirv(file.get_spirv())
	var specialization := RDPipelineSpecializationConstant.new()
	specialization.constant_id=0;specialization.value=GRID
	var pipeline := rd.compute_pipeline_create(shader,[specialization])
	var grid_uniform := RDUniform.new()
	grid_uniform.uniform_type=RenderingDevice.UNIFORM_TYPE_IMAGE;grid_uniform.binding=0;grid_uniform.add_id(texture)
	var elem_uniform := RDUniform.new()
	elem_uniform.uniform_type=RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER;elem_uniform.binding=1;elem_uniform.add_id(elements)
	var uniform_set := rd.uniform_set_create([grid_uniform,elem_uniform],shader,0)
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl,pipeline)
	rd.compute_list_bind_uniform_set(cl,uniform_set,0)
	var push := PackedInt32Array([0,0,1,50]).to_byte_array()
	rd.compute_list_set_push_constant(cl,push,push.size())
	rd.compute_list_dispatch(cl,GRID/8,GRID/8,1)
	rd.compute_list_end()
	var actual := rd.texture_get_data(texture,0)
	var rows := []
	for x in cases.size():
		var equal := true
		var id_equal := true
		var before_mass := 0
		var after_mass := 0
		for amount in cases[x].amounts:before_mass+=int(amount)
		for y in GRID:
			var expected := int(cases[x].target[y]) if y<cases[x].target.size() else 0
			var offset: int = (x+GRID*y)*4
			equal = equal and actual[offset+2]==expected
			id_equal = id_equal and actual[offset]==(Elements.Id.WATER if expected>0 else Elements.Id.AIR)
			after_mass+=actual[offset+2]
		rows.append({"index":x,"count":cases[x].amounts.size(),"amount_equal":equal,"id_equal":id_equal,"mass_equal":before_mass==after_mass})
	for rid in [uniform_set,pipeline,shader,texture,elements]:rd.free_rid(rid)
	finished.emit.call_deferred({"rows":rows})

func _check(ok: bool, message: String) -> void:
	_checks+=1
	if ok:print("ok: "+message)
	else:
		_failures+=1
		push_error(message)
