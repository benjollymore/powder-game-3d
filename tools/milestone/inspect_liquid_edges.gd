extends SceneTree
## Frozen native-resolution liquid cap; debug R identifies liquid entry events.
const OUT := "res://docs/milestone/liquid-edge-evidence"
var sim: Node3D
var camera: Camera3D

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(600,600)
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
	camera = Camera3D.new()
	camera.near = 0.001
	camera.fov = 50
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.08,0.12,0.18)
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	for i in 30:
		await process_frame
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data,Vector3i.ONE*VoxelCodec.GRID/8,Vector3i.ONE*VoxelCodec.GRID*7/8,Elements.Id.WATER)
	var bytes := data.to_byte_array()
	sim.upload(bytes)
	sim.set_param("section_enabled",true)
	sim.set_param("section_axis",2)
	sim.set_param("section_cell",VoxelCodec.GRID/2-1)
	var source := FileAccess.get_file_as_string("res://tests/milestone/fixtures/voxel_volume_edge_baseline.gdshader")
	source = source.replace("float dbg_leaps = 0.0;", "float dbg_leaps = 0.0;\n\tfloat dbg_missed_exit = 0.0;")
	source = source.replace("\t\tf_prev = f;", "\t\tif (in_liquid && !liquid && !prev_liquid && f < 0.5) { dbg_missed_exit = 1.0; }\n\t\tf_prev = f;")
	source = source.replace("\tif (volume_debug == 3) {", "\tif (volume_debug == 4) { ALBEDO = vec3(dbg_missed_exit, 0.0, 0.0); ALPHA = 1.0; }\n\tif (volume_debug == 3) {")
	var diagnostic := Shader.new()
	diagnostic.code = source
	var material: ShaderMaterial = sim.get_node("VolumeMesh").material_override
	material.shader = diagnostic
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var rows: Array[Dictionary] = []
	for view in [{"name":"front","pos":Vector3(0,0,1.2)}, {"name":"oblique","pos":Vector3(0.3,0.2,1.2)}]:
		camera.position = view.pos * sim.world_size()
		camera.look_at(Vector3.ZERO)
		for mode in [0,3,4]:
			sim.set_param("volume_debug",mode)
			for i in 15:
				await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			var name: String = view.name + ({0:"-normal",3:"-entry-debug",4:"-missed-exit-debug"}[mode])
			assert(img.save_png(OUT+"/"+name+".png")==OK)
			if mode>0:
				var count := 0
				var entries := 0
				for y in img.get_height():
					for x in img.get_width():
						var pixel := Vector2(x+0.5,y+0.5)
						var origin := camera.project_ray_origin(pixel)
						var ray := camera.project_ray_normal(pixel)
						var p := origin + ray * (-origin.z/ray.z)
						var limit: float = sim.world_size()*0.375 - 2.0*sim.world_size()/VoxelCodec.GRID
						if absf(p.x)<limit and absf(p.y)<limit:
							count += 1
							if img.get_pixel(x,y).r>0.5:
								entries += 1
				var row := {"view":view.name,"debug_mode":mode,"interior_cap_pixels":count,"marked_pixels":entries}
				rows.append(row)
				print(JSON.stringify(row))
	var readback: Array[PackedByteArray] = []
	sim.request_readback(func(b: PackedByteArray): readback.append(b))
	var deadline := Time.get_ticks_msec()+15000
	while readback.is_empty() and Time.get_ticks_msec()<deadline:
		await process_frame
	assert(not readback.is_empty() and readback[0]==bytes,"Frozen physical state changed")
	var file := FileAccess.open(OUT+"/diagnosis.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	print("LIQUID_EDGE_DIAGNOSTIC_STATE_UNCHANGED")
	quit()
