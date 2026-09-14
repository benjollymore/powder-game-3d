extends "res://tools/milestone/capture_presentation.gd"
## Reuse the frozen material specimen; change only the liquid exit shader.
const EXIT_OUT := "res://docs/milestone/liquid-edge-evidence"

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(1600,900)
	stage = Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	stage.add_child(sim)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.fov = 55
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	stage.add_child(world)
	Presentation.apply(sim,world,stage)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(EXIT_OUT))
	for i in 30:
		await process_frame
	var bytes := _build()
	sim.upload(bytes)
	for c in [{"name":"stage-ordinary","camera":Vector3(0.9,0.55,1.0),"section":false,"axis":2},
			{"name":"stage-section-z","camera":Vector3(0.8,0.5,1.0),"section":true,"axis":2},
			{"name":"stage-section-x","camera":Vector3(1.0,0.5,0.8),"section":true,"axis":0}]:
		camera.position = c.camera*sim.world_size()
		camera.look_at(Vector3(0,-0.08,0)*sim.world_size())
		sim.set_param("section_enabled",c.section)
		sim.set_param("section_axis",c.axis)
		sim.set_param("section_cell",VoxelCodec.GRID/2-1)
		for baseline in [true,false]:
			var material: ShaderMaterial = sim.get_node("VolumeMesh").material_override
			material.shader = load("res://tests/milestone/fixtures/voxel_volume_edge_baseline.gdshader" if baseline else "res://shaders/spatial/voxel_volume.gdshader")
			for i in 30:
				await process_frame
			await RenderingServer.frame_post_draw
			var name: String = c.name + ("-baseline" if baseline else "-fixed")
			assert(root.get_texture().get_image().save_png(EXIT_OUT+"/"+name+".png")==OK)
			print("CAPTURE ",name)
	var readback: Array[PackedByteArray] = []
	sim.request_readback(func(data: PackedByteArray): readback.append(data))
	var deadline := Time.get_ticks_msec()+15000
	while readback.is_empty() and Time.get_ticks_msec()<deadline:
		await process_frame
	assert(not readback.is_empty() and readback[0]==bytes,"Frozen physical state changed")
	print("LIQUID_EXIT_STAGE_UNCHANGED ",_hash(bytes)," scale=",root.scaling_3d_scale," aa=",root.screen_space_aa)
	quit()
