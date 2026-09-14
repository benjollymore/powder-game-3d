extends SceneTree
## Paired native-resolution frozen-frame wall times and synchronized preparation
## wall times. These are not device timestamps or physics-tick measurements.
signal ready_result(value: Variant)
var sim: Node3D
var original := {}
var legacy := {}
var resources: Array[RID] = []
const OUT := "res://docs/milestone/material-capacity-evidence/cost"

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(120).timeout.connect(func(): push_error("Capacity cost timeout"); quit(2))
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(900,700)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var stage := Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	stage.add_child(sim)
	var camera := Camera3D.new()
	stage.add_child(camera)
	camera.position = Vector3(0.7,0.8,1)*sim.world_size()
	camera.look_at(Vector3.ZERO)
	camera.near = 0.001
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.7
	stage.add_child(world)
	for i in 20: await process_frame
	var data := WorldBuilder.empty()
	var count := 0
	for z in range(24,105,3):
		for y in range(24,105,3):
			for x in range(24,105,3):
				var id: int = [Elements.Id.SAND,Elements.Id.PLANT,Elements.Id.WATER][count%3]
				var flags: int = 6 if id==Elements.Id.SAND else (1 if id==Elements.Id.WATER else 0)
				data[VoxelCodec.index(x,y,z)] = VoxelCodec.encode(id,WorldBuilder.seed_at(x,y,z),50 if id==Elements.Id.WATER else 0)|(flags<<24)
				count += 1
	sim.upload(data.to_byte_array())
	for i in 10: await process_frame
	RenderingServer.call_on_render_thread(_rt_install)
	await ready_result
	var shaders := {}
	for variant in ["legacy","candidate"]:
		shaders[variant] = []
		for name in ["voxel_opaque","voxel_volume"]:
			var path: String = "res://tests/milestone/fixtures/"+name+"_capacity_baseline.txt" if variant=="legacy" else "res://shaders/spatial/"+name+".gdshader"
			var shader := Shader.new()
			shader.code = FileAccess.get_file_as_string(path)
			shaders[variant].append(shader)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var rows: Array[Dictionary] = []
	for repeat in 3:
		for variant in (["legacy","candidate"] if repeat%2==0 else ["candidate","legacy"]):
			RenderingServer.call_on_render_thread(_rt_mode.bind(variant))
			await ready_result
			sim.get_node("Mesh").material_override.shader = shaders[variant][0]
			sim.get_node("VolumeMesh").material_override.shader = shaders[variant][1]
			sim.set_param("physical_overflow",sim._physical_overflow_texture)
			for i in 30: await process_frame
			var frame_ms: Array[float] = []
			var previous := Time.get_ticks_usec()
			for i in 120:
				await RenderingServer.frame_post_draw
				var now := Time.get_ticks_usec()
				frame_ms.append((now-previous)/1000.0)
				previous = now
				await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(OUT+"/"+variant+".png")
			RenderingServer.call_on_render_thread(_rt_bench)
			var prep_ms: Array = await ready_result
			frame_ms.sort()
			prep_ms.sort()
			var row := {"variant":variant,"repeat":repeat,"physical_cells":count,"frame_median_ms":frame_ms[60],"frame_p95_ms":frame_ms[114],"preparation_sync_median_ms":prep_ms[5],"preparation_sync_p95_ms":prep_ms[9]}
			rows.append(row)
			print(JSON.stringify(row))
	var file := FileAccess.open(OUT+"/cost.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	RenderingServer.call_on_render_thread(_rt_cleanup)
	await ready_result
	quit(0)

func _rt_install() -> void:
	var rd: RenderingDevice = sim._rd
	for name in ["splat_emit","fields"]:
		var prefix: String = "_splat" if name=="splat_emit" else "_density"
		for suffix in ["_shader","_pipeline","_set"]: original[prefix+suffix] = sim.get(prefix+suffix)
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string("res://tests/milestone/fixtures/"+name+"_capacity_baseline.txt").replace("#[compute]","")
		# Layout adapter only: the original field formulas use elapsed at byte16.
		if name=="fields": source.source_compute = source.source_compute.replace("vec4 elapsed;","uvec4 unused_cap;\n\tvec4 elapsed;")
		var spirv := rd.shader_compile_spirv_from_source(source)
		assert(spirv.compile_error_compute.is_empty(),spirv.compile_error_compute)
		var shader := rd.shader_create_from_spirv(spirv)
		var pipeline := rd.compute_pipeline_create(shader,sim._spec([VoxelCodec.GRID]))
		var uniforms: Array[RDUniform]
		if name=="splat_emit":
			uniforms = [sim._image_uniform(0),sim._image_uniform(1,sim._occ_rid),sim._buffer_uniform(2,sim._elements_buffer),sim._buffer_uniform(3,sim._splat_counter),sim._buffer_uniform(4,sim._layer_buffer[0]),sim._buffer_uniform(5,sim._layer_buffer[1]),sim._buffer_uniform(6,sim._layer_buffer[2]),sim._buffer_uniform(7,sim._fx_spawns)]
		else:
			uniforms = [sim._image_uniform(0),sim._image_uniform(1,sim._fields_views[0]),sim._buffer_uniform(2,sim._elements_buffer)]
		var uniform_set := rd.uniform_set_create(uniforms,shader,0)
		legacy[prefix+"_shader"] = shader
		legacy[prefix+"_pipeline"] = pipeline
		legacy[prefix+"_set"] = uniform_set
		resources.append_array([uniform_set,pipeline,shader])
	ready_result.emit.call_deferred(true)

func _rt_mode(variant: String) -> void:
	var selected: Dictionary = legacy if variant=="legacy" else original
	for key in selected: sim.set(key,selected[key])
	sim._rt_occupancy_update()
	ready_result.emit.call_deferred(true)

func _rt_bench() -> void:
	var samples: Array[float] = []
	for i in 12:
		var start := Time.get_ticks_usec()
		sim._rt_occupancy_update()
		sim._rd.texture_get_data(sim._sunvis_rid,0) # final preparation output, including readback cost
		var elapsed := (Time.get_ticks_usec()-start)/1000.0
		if i>=2: samples.append(elapsed)
	ready_result.emit.call_deferred(samples)

func _rt_cleanup() -> void:
	for key in original: sim.set(key,original[key])
	for rid in resources: sim._rd.free_rid(rid)
	ready_result.emit.call_deferred(true)
