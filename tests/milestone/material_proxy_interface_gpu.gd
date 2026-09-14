extends "res://tests/milestone/material_proxy_geometry_gpu.gd"
## Reflection-entry gates. Bulk length/coverage remains covered by the inherited
## geometry harness, run separately. No solver steps or material-byte edits.
const SURFACE_OUT := "res://docs/milestone/material-interface-evidence/gates"

func _run() -> void:
	root.size = Vector2i(320,320)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var stage := Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	sim.get_node("Droplets").capacity = 1
	stage.add_child(sim)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.far = 100
	camera.fov = 45
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLACK
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	for i in 20: await process_frame
	var source := FileAccess.get_file_as_string("res://shaders/spatial/voxel_volume.gdshader")
	source = source.replace("float previous_liquid_exit = -1.0;", "float previous_liquid_exit = -1.0;\n\tfloat proxy_reflections = 0.0;")
	source = source.replace("if (proxy_surface_reflection && air_entry && !cut_entry && !touching_full_liquid(r.cell, proxy_normal, fill, liquid_full)) {", "if (proxy_surface_reflection && air_entry && !cut_entry && !touching_full_liquid(r.cell, proxy_normal, fill, liquid_full)) {\n\t\t\t\t\tproxy_reflections += 1.0;")
	source = source.replace("\tif (volume_debug == 3) {", "\tif (volume_debug == 5) { ALBEDO = vec3(proxy_reflections / 4.0); ALPHA = 1.0; }\n\tif (volume_debug == 3) {")
	var shader := Shader.new()
	shader.code = source
	sim.get_node("VolumeMesh").material_override.shader = shader
	sim.set_param("physical_overflow",sim._physical_overflow_texture)
	sim.set_param("volume_debug",5)
	var cell_size: float = sim.world_size()/VoxelCodec.GRID
	var center := (Vector3(TARGET)+Vector3.ONE*0.5-Vector3.ONE*VoxelCodec.GRID*0.5)*cell_size
	var blocker := MeshInstance3D.new()
	var mesh := QuadMesh.new()
	mesh.size = Vector2.ONE*cell_size*2
	blocker.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color.BLACK
	blocker.material_override = material
	blocker.position = center+Vector3(0,0,0.8)*cell_size
	blocker.visible = false
	stage.add_child(blocker)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SURFACE_OUT))
	var cases := [
		{"name":"front","amount":200,"expected":1},
		{"name":"inside","amount":200,"expected":0},
		{"name":"section-cap","amount":200,"expected":0},
		{"name":"section-cap-x","axis":0,"amount":200,"expected":0},
		{"name":"section-cap-y","axis":1,"amount":200,"expected":0},
		{"name":"partial-inside-section","amount":50,"expected":1},
		{"name":"touching","amount":200,"expected":1},
		{"name":"ordinary-liquid-join","amount":200,"expected":0},
		{"name":"separated","amount":200,"expected":2},
		{"name":"opaque-blocker","amount":200,"expected":0},
		{"name":"removed","amount":200,"expected":0}]
	var results: Array[Dictionary] = []
	for c in cases:
		var other := Vector3i(8,8,8)
		if c.name=="touching": other = TARGET-Vector3i(0,0,1)
		if c.name=="separated": other = TARGET-Vector3i(0,0,2)
		var data := WorldBuilder.empty()
		for p in [TARGET,other]:
			data[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(Elements.Id.WATER,17,c.amount)|(1<<24)
		if c.name=="ordinary-liquid-join":
			var front := TARGET+Vector3i(0,0,1)
			data[VoxelCodec.index(front.x,front.y,front.z)] = VoxelCodec.encode(Elements.Id.WATER,29,200)
		var bytes := data.to_byte_array()
		sim.upload(bytes)
		var axis: int = c.get("axis",2)
		var offset := Vector3.ZERO
		offset[axis] = 3*cell_size
		camera.position = center+(Vector3.ZERO if c.name=="inside" else offset)
		camera.look_at(center-Vector3(0,0,cell_size) if c.name=="inside" else center,Vector3.FORWARD if axis==1 else Vector3.UP)
		sim.set_param("section_enabled",c.name.begins_with("section-cap") or c.name in ["partial-inside-section","removed"])
		sim.set_param("section_axis",axis)
		sim.set_param("section_cell",63 if c.name=="removed" else 64)
		blocker.visible = c.name=="opaque-blocker"
		for enabled in [false,true]:
			sim.set_param("proxy_surface_reflection",enabled)
			for i in 6: await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var actual := image.get_pixel(160,160).srgb_to_linear().r*4
			var expected: float = c.expected if enabled else 0
			_check(absf(actual-expected)<0.035,c.name+" correct number of physical reflection entries")
			_check(image.save_png(SURFACE_OUT+"/%s-%s.png"%[c.name,"on" if enabled else "off"])==OK,"save interface gate")
			results.append({"case":c.name,"reflection":enabled,"expected_entries":expected,"measured_entries":actual})
		RenderingServer.call_on_render_thread(_rt_snapshot)
		var state: Dictionary = await snapshot_ready
		_check(state.voxels==bytes,"surface shading preserves complete physical bytes")
		_check(state.overflow[2]==255,"fixture uses actual overflow mode")
	var file := FileAccess.open(SURFACE_OUT+"/regression.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(results,"\t"))
	file.close()
	print("PROXY_INTERFACE_CHECKS %d FAILURES %d"%[checks,failures])
	quit(0 if failures==0 else 1)
