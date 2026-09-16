extends SceneTree
## A one-cell-thick liquid sheet with AIR (or gas) below as well as above: the
## configuration in which ordinary_thin() fires for every interior cell, so the
## volume pass mixes analytic slab proxies with the isosurface marcher. Paused,
## authored bytes only, close steep view.
signal ready_result(value: Variant)
var sim: Node3D
var OUT := "res://docs/milestone/lattice-evidence/float"
var amount := 200
var under := "air"
var eye_h := 26.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): OUT = arg.trim_prefix("output_dir=")
		elif arg.begins_with("amount="): amount = int(arg.trim_prefix("amount="))
		elif arg.begins_with("under="): under = arg.trim_prefix("under=")
		elif arg.begins_with("eye="): eye_h = float(arg.trim_prefix("eye="))
	root.get_node("TimeController").paused = true
	create_timer(420).timeout.connect(func(): push_error("Lattice float timeout"); quit(2))
	call_deferred("_run")


func _capture(name: String) -> void:
	for i in 5: await process_frame
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

	var sheet_y := 40
	var data := WorldBuilder.empty()
	# Distant floor so the sheet is unmistakably unsupported.
	for z in range(0, n):
		for x in range(0, n):
			data[VoxelCodec.index(x, 4, z)] = VoxelCodec.encode(Elements.Id.WALL, 11, 0)
	if under == "steam":
		for z in range(8, n - 8):
			for x in range(8, n - 8):
				data[VoxelCodec.index(x, sheet_y - 1, z)] = VoxelCodec.encode(Elements.Id.STEAM, 13, 0)
	for z in range(8, n - 8):
		for x in range(8, n - 8):
			data[VoxelCodec.index(x, sheet_y, z)] = VoxelCodec.encode(Elements.Id.WATER, 17, amount)
	sim.upload(data.to_byte_array())
	for i in 12: await process_frame

	var world_size: float = sim.world_size()
	var cell: float = world_size / float(n)
	var surf := (sheet_y + 1) * cell - world_size * 0.5
	camera.position = Vector3(0.0, surf + eye_h * cell, 34.0 * cell)
	camera.look_at(Vector3(0.0, surf, -10.0 * cell))
	camera.near = 0.001
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	var tag := "%s-a%d-e%d" % [under, amount, int(eye_h)]
	await _capture(tag + "-00-default")
	# Let the unsupported sheet fall: thin falling liquid becomes droplet sprites.
	for step in range(1, 25):
		sim.request_ticks(1)
		await process_frame
		if step in [2, 4, 6, 9, 12, 18, 24]:
			await _capture(tag + "-fall%02d" % step)
	await _capture(tag + "-fall-end")
	sim.set_param("droplet_fallback", false)
	await _capture(tag + "-fall-no-droplets")
	sim.set_param("droplet_fallback", true)
	sim.set_param("ordinary_thin_proxy", false)
	await _capture(tag + "-01-no-thin-proxy")
	sim.set_param("ordinary_thin_proxy", true)
	sim.set_param("foam_strength", 0.0)
	await _capture(tag + "-02-no-foam")
	sim.set_param("foam_strength", 1.0)
	print("LATTICE_FLOAT grid=%d amount=%d under=%s" % [n, amount, under])
	quit(0)
