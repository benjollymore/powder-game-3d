extends SceneTree
## Close grazing view of supported liquid films at a sweep of fill amounts on an
## inert floor. No solver steps: the authored bytes are exactly what is drawn, so
## any hole in the image is a rendering result, not a simulation one.
signal ready_result(value: Variant)
var sim: Node3D
var OUT := "res://docs/milestone/lattice-evidence/film"
var depth := 1

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): OUT = arg.trim_prefix("output_dir=")
		elif arg.begins_with("depth="): depth = int(arg.trim_prefix("depth="))
	root.get_node("TimeController").paused = true
	create_timer(420).timeout.connect(func(): push_error("Lattice film timeout"); quit(2))
	call_deferred("_run")


func _capture(name: String) -> void:
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT + "/" + name + ".png")


func _run() -> void:
	root.size = Vector2i(1060, 560)
	root.scaling_3d_scale = 1.0
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	var stage := Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	stage.add_child(sim)
	var camera := Camera3D.new()
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(0.67, 0.74, 0.84)
	world.environment.ambient_light_energy = 1.0
	stage.add_child(world)
	for i in 20: await process_frame

	var n := VoxelCodec.GRID
	var palette := Elements.palette()
	palette[Elements.Id.WALL] = Color(0.34, 0.40, 0.46, 0.0)
	palette[Elements.Id.WATER] = Color(0.08, 0.37, 0.62, 0.0)
	sim.set_param("palette", palette)

	# Inert wall floor; bands of film across z, each band a different fill.
	var amounts := [200, 150, 120, 100, 80, 60, 40, 20]
	var floor_top := 12
	var data := WorldBuilder.empty()
	for z in range(0, n):
		for x in range(0, n):
			for y in range(4, floor_top):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WALL, 11, 0)
	var band := int(float(n - 16) / float(amounts.size()))
	for i in amounts.size():
		var z0 := 8 + i * band
		for z in range(z0, z0 + band - 2):
			for x in range(8, n - 8):
				for y in range(floor_top, floor_top + depth):
					data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WATER, 17, int(amounts[i]))
	sim.upload(data.to_byte_array())
	for i in 12: await process_frame

	var world_size: float = sim.world_size()
	var cell: float = world_size / float(n)
	# Eye just above the film, looking along it: the grazing view in the report.
	# Close and steep, so one cell spans roughly 16 px as in the report.
	var surf := (floor_top + depth) * cell - world_size * 0.5
	camera.position = Vector3(0.0, surf + 9.0 * cell, 30.0 * cell)
	camera.look_at(Vector3(0.0, surf + 1.0 * cell, -26.0 * cell))
	camera.near = 0.001
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	for sc in [1.0, 0.75]:
		root.scaling_3d_scale = sc
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		for i in 4: await process_frame
		await _capture("depth%d-scale%03d" % [depth, int(sc * 100)])
	root.scaling_3d_scale = 1.0
	await _capture("depth%d-00-default" % depth)
	sim.set_param("ordinary_thin_proxy", false)
	await _capture("depth%d-01-no-thin-proxy" % depth)
	sim.set_param("ordinary_thin_proxy", true)
	sim.set_param("foam_strength", 0.0)
	await _capture("depth%d-02-no-foam" % depth)
	sim.set_param("foam_strength", 1.0)

	print("LATTICE_FILM grid=%d depth=%d amounts=%s" % [n, depth, str(amounts)])
	quit(0)
