extends SceneTree
## Load Ben's saved world and sweep the camera around it, so his reported
## lattice can be found in his own bytes rather than guessed at with fixtures.
## Also reports what the world actually contains, per element.
var sim: Node3D
var out_dir := "res://docs/milestone/wax-lattice-evidence/construction"
var path := "res://tests/milestone/fixtures/construction.p3d"
var caustics := 1.0
var single := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): out_dir = arg.trim_prefix("output_dir=")
		elif arg.begins_with("path="): path = arg.trim_prefix("path=")
		elif arg.begins_with("caustics="): caustics = float(arg.trim_prefix("caustics="))
		elif arg.begins_with("single="): single = arg.trim_prefix("single=") == "1"
	root.get_node("TimeController").paused = true
	create_timer(420).timeout.connect(func(): push_error("Construction capture timeout"); quit(2))
	call_deferred("_run")

func _frames(n: int) -> void:
	for i in n: await process_frame

func _capture(name: String) -> void:
	await _frames(6)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(out_dir + "/" + name + ".png")

func _run() -> void:
	var loaded := WorldArchive.load_authored(path, VoxelCodec.GRID)
	if loaded.has("error") and loaded.error != "":
		push_error("load failed: %s" % loaded.error)
		quit(2)
		return
	var bytes: PackedByteArray = loaded.bytes
	var n: int = VoxelCodec.GRID
	# What is actually in here, and where.
	var counts := {}
	var lowest := {}
	var highest := {}
	for i in range(0, bytes.size(), 4):
		var id := bytes[i]
		if id == 0: continue
		counts[id] = int(counts.get(id, 0)) + 1
		var cell := i / 4
		var y := (cell / n) % n
		lowest[id] = mini(int(lowest.get(id, n)), y)
		highest[id] = maxi(int(highest.get(id, -1)), y)
	for id in counts:
		print("ELEMENT %d %s count=%d y=%d..%d" % [id, Elements.TABLE[id]["name"], counts[id], lowest[id], highest[id]])

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
	camera.near = 0.001
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(0.67, 0.74, 0.84)
	world.environment.ambient_light_energy = 1.0
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52.0, 37.0, 0.0)
	stage.add_child(sun)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	await _frames(12)

	if loaded.has("thermal") and loaded.thermal is PackedByteArray and not loaded.thermal.is_empty():
		sim.upload(bytes, loaded.thermal)
	else:
		sim.upload(bytes)
	await _frames(12)

	sim.set_param("caustic_strength", caustics)
	await _frames(4)
	var size: float = sim.world_size()
	var cell := size / float(n)
	var centre := Vector3.ZERO
	if single:
		camera.position = Vector3(0.62 * size, (4.0 / float(n) - 0.5) * size, 0.0)
		camera.look_at(centre)
		await _capture("submerged-caustics-%d" % int(caustics))
		print("CONSTRUCTION_CAPTURE done")
		quit(0)
		return
	# A grazing orbit at a few heights, which is how he was looking at it.
	for h in [4, 10, 20, 34]:
		for step in 6:
			var ang := TAU * float(step) / 6.0
			var r := 0.62 * size
			camera.position = Vector3(cos(ang) * r, (float(h) / float(n) - 0.5) * size, sin(ang) * r)
			camera.look_at(centre)
			await _capture("h%02d-a%d" % [h, step])
	print("CONSTRUCTION_CAPTURE done")
	quit(0)
