extends "res://tests/milestone/ordinary_liquid_probe.gd"
## Unchanged bulk/film controls and explicit thin/thick/tilted visual limits.
func _run() -> void:
	var destination := "res://docs/milestone/ordinary-liquid-evidence/controls"
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
	stage.add_child(sim)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.far = 100
	camera.fov = 45
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	for i in 20: await process_frame
	var cell_size: float = sim.world_size()/VoxelCodec.GRID
	var center := (Vector3(TARGET)+Vector3.ONE*0.5-Vector3.ONE*VoxelCodec.GRID*0.5)*cell_size
	camera.position = center+Vector3(5,6,8)*cell_size
	camera.look_at(center)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination))
	var results: Array[Dictionary] = []
	for name in ["bulk-full","supported-film","thin-full","thick-full","tilted-partial","thick-low-fill-unresolved"]:
		var data := WorldBuilder.empty()
		var cells: Array[Vector3i] = []
		if name=="supported-film":
			for z in range(-3,4):
				for x in range(-3,4):
					var p := TARGET+Vector3i(x,-1,z)
					data[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(Elements.Id.WALL,17,0)
		var height := 4 if name=="bulk-full" else (2 if name in ["thick-full","thick-low-fill-unresolved"] else 1)
		var amount := 50 if name in ["supported-film","tilted-partial","thick-low-fill-unresolved"] else 200
		for z in range(-2,3):
			for y in height:
				for x in range(-2,3):
					var p := TARGET+Vector3i(x,z if name=="tilted-partial" else y,z)
					data[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(Elements.Id.WATER,17,amount)
					cells.append(p)
		var bytes := data.to_byte_array()
		sim.upload(bytes)
		var images := {}
		for enabled in [false,true]:
			sim.set_param("ordinary_thin_proxy",enabled)
			for i in 5: await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			_check(image.save_png(destination+"/%s-%s.png"%[name,"on" if enabled else "off"])==OK,"save topology/control capture")
			images[enabled] = image.get_data()
		var identical: bool = images[false]==images[true]
		if name in ["bulk-full","supported-film","thick-full","thick-low-fill-unresolved"]: _check(identical,name+" outside rescue is exactly unchanged")
		RenderingServer.call_on_render_thread(_rt_probe_snapshot.bind(cells))
		var state: Dictionary = await snapshot_ready
		_check(state.voxels==bytes,"control retains every physical byte")
		_check(state.droplets==0 and state.overflow==0,"ordinary controls do not use sprites/overflow")
		results.append({"case":name,"amount":amount,"liquid_cells":cells.size(),"images_identical":identical,"voxel_sha256":_sha256(bytes)})
	var file := FileAccess.open(destination+"/controls.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(results,"\t")); file.close()
	print("ORDINARY_CONTROLS_CHECKS %d FAILURES %d"%[checks,failures])
	quit(0 if failures==0 else 1)
