extends SceneTree
## Frozen renderer A/B: Tab switches look; B runs measurements; Esc exits.
## godot --path . --always-on-top --disable-vsync -s res://tools/discovery/rendering.gd -- batch=1
var main: Node3D
var sim: Node3D
var clean := false
var caption: Label
var baseline_env: Environment
var baseline_palette: PackedColorArray
var rows: Array[Dictionary] = []
var output := "res://docs/discovery/rendering-evidence"
var busy := false
var scene_name := "material-lab"
var initial_hash := ""

func _initialize() -> void:
	call_deferred("_start")

func _start() -> void:
	root.get_node("TimeController").paused = true
	main = load("res://scenes/main.tscn").instantiate()
	sim = main.get_node("SimVolume")
	sim.listen_to_time_controller = false
	sim.fx_enabled = false
	sim.current_scenario = "Empty"
	root.add_child(main)
	current_scene = main
	main.get_node("HUD").hide()
	main.get_node("Brush").process_mode = Node.PROCESS_MODE_DISABLED
	main.get_node("Brush/Gizmo").hide()
	main.get_node("Audio").process_mode = Node.PROCESS_MODE_DISABLED
	main.get_node("Environment/PostFX").hide()
	baseline_env = main.get_node("Environment/WorldEnvironment").environment.duplicate(true)
	baseline_palette = Elements.palette()
	var rig: Node3D = main.get_node("CameraRig")
	rig.frame_position = Vector3(0.68, 0.48, 0.80) * sim.world_size()
	rig.orbit_target = Vector3(0.0, -0.28, 0.0) * sim.world_size()
	rig.frame_box(false)
	rig._base_fov = 55.0
	rig.camera.fov = 55.0
	var overlay := CanvasLayer.new()
	root.add_child(overlay)
	caption = Label.new()
	caption.position = Vector2(28, 24)
	caption.add_theme_font_size_override("font_size", 22)
	caption.add_theme_color_override("font_color", Color(0.14, 0.18, 0.23))
	overlay.add_child(caption)
	for i in 30:
		await process_frame
	await _load_lab()
	_set_look(true)
	var batch := "batch=1" in OS.get_cmdline_user_args()
	if batch:
		await _bench_all()
		quit()
	else:
		process_frame.connect(_keys)

var last_tab := false
var last_b := false
func _keys() -> void:
	var tab := Input.is_key_pressed(KEY_TAB)
	var b := Input.is_key_pressed(KEY_B)
	if tab and not last_tab and not busy:
		_set_look(not clean)
	if b and not last_b and not busy:
		_bench_all()
	if Input.is_key_pressed(KEY_ESCAPE):
		quit()
	last_tab = tab
	last_b = b

func _load_lab() -> void:
	scene_name = "material-lab"
	var d := WorldBuilder.empty()
	_box(d, Vector3i(12, 3, 16), Vector3i(116, 7, 110), Elements.Id.WALL)
	WorldBuilder.fill_bowl(d, _v(Vector3i(17, 7, 21)), _v(Vector3i(68, 35, 76)), maxi(2, VoxelCodec.GRID / 64))
	_box(d, Vector3i(20, 10, 24), Vector3i(65, 29, 73), Elements.Id.WATER)
	# A submerged step makes depth/absorption legible.
	_box(d, Vector3i(22, 10, 44), Vector3i(38, 20, 70), Elements.Id.WALL)
	# Authored cone on a separate raised tray; no claim that this was simulated.
	_box(d, Vector3i(72, 7, 45), Vector3i(111, 11, 92), Elements.Id.WALL)
	var g := float(VoxelCodec.GRID) / 128.0
	for y in range(int(11 * g), int(39 * g)):
		var radius := (39.0 * g - y) * 0.64
		for z in range(int(48 * g), int(90 * g)):
			for x in range(int(74 * g), int(111 * g)):
				if Vector2(x - 92 * g, z - 69 * g).length() < radius:
					d[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.SAND, WorldBuilder.seed_at(x, y, z), 0)
	# Synthetic movement flags exercise airborne-grain and thin-spray rendering.
	# These are authored frozen cells, not the result of a simulated pour.
	for y in range(44, 66, 2):
		var p := _v(Vector3i(92, y, 69))
		d[VoxelCodec.index(p.x, p.y, p.z)] = VoxelCodec.encode(Elements.Id.SAND, y * 3, 0) | (6 << 24)
		p = _v(Vector3i(49, y, 42))
		d[VoxelCodec.index(p.x, p.y, p.z)] = VoxelCodec.encode(Elements.Id.WATER, y * 3, 150) | (1 << 24)
	await _upload(d.to_byte_array())

func _sha(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()

func _v(v: Vector3i) -> Vector3i:
	return Vector3i(Vector3(v) * float(VoxelCodec.GRID) / 128.0)

func _box(d: PackedInt32Array, lo: Vector3i, hi: Vector3i, id: int) -> void:
	WorldBuilder.fill_box(d, _v(lo), _v(hi), id)

func _upload(bytes: PackedByteArray) -> void:
	initial_hash = _sha(bytes)
	sim.upload(bytes)
	for i in 45:
		await process_frame

func _set_look(value: bool) -> void:
	clean = value
	var atmo: Node3D = main.get_node("Environment")
	var env: Environment = baseline_env.duplicate(true)
	atmo.get_node("WorldEnvironment").environment = env
	atmo.dof_enabled = not clean
	atmo.motion_blur_enabled = not clean
	atmo.get_node("BoundsOutline").visible = not clean
	atmo.get_node("BoxFrame").visible = not clean
	var pal := baseline_palette.duplicate()
	if clean:
		env.ambient_light_energy = 0.8
		env.adjustment_saturation = 1.0
		env.adjustment_contrast = 1.0
		env.glow_enabled = false
		env.fog_enabled = false
		env.ssao_enabled = false
		pal[Elements.Id.WALL] = Color(0.29, 0.34, 0.37)
		pal[Elements.Id.SAND] = Color(0.88, 0.59, 0.23)
		pal[Elements.Id.WATER] = Color(0.06, 0.40, 0.43)
	var ground: ShaderMaterial = atmo.get_node("Ground").get_surface_override_material(0)
	ground.set_shader_parameter("albedo", Color(0.77, 0.80, 0.82) if clean else Color(0.88, 0.89, 0.91))
	sim.set_param("palette", pal)
	sim.set_param("detail_strength", 0.0 if clean else 1.0)
	sim.set_param("caustic_strength", 0.0 if clean else 1.0)
	sim.set_param("ao_strength", 0.8 if clean else 1.0)
	sim.set_param("refraction", 0.008 if clean else 0.045)
	sim.set_param("foam_strength", 0.15 if clean else 1.0)
	sim.set_param("absorb", Vector3(0.022, 0.009, 0.006) if clean else Vector3(0.10, 0.045, 0.02))
	sim.set_param("scatter", 0.014 if clean else 0.05)
	sim.set_param("liquid_specular", 0.3 if clean else 0.7)
	# These layers are physical representations: fields.glsl excludes airborne
	# grains and thin spray. Keep them visible in both variants.
	for child_name in ["Splats", "Leaves", "Droplets"]:
		sim.get_node(child_name).visible = true
	sim.get_node("Fx").visible = false
	caption.text = "MATERIAL STUDY  /  %s\n%s  ·  frozen %d³ state\nTab compare   ·   RMB + WASD explore   ·   B benchmark" % [scene_name, "Clean study" if clean else "Existing materials", VoxelCodec.GRID]

func _bench_all() -> void:
	busy = true
	rows.clear()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	# Alternating repeats expose order/thermal variation. Same bytes for each pair.
	for scene_index in 2:
		if scene_index == 0:
			await _load_lab()
		else:
			scene_name = "dam-break"
			await _upload(Scenarios.build("Dam break"))
		for repeat in 2:
			for variant in [false, true]:
				_set_look(variant)
				for i in 90:
					await process_frame
				var samples: Array[float] = []
				var start := Time.get_ticks_usec()
				for i in 240:
					await process_frame
					var now := Time.get_ticks_usec()
					samples.append((now - start) / 1000.0)
					start = now
				var total := 0.0
				for ms in samples:
					total += ms
				samples.sort()
				var row := {"scene": scene_name, "variant": "clean" if clean else "baseline", "repeat": repeat, "mean_ms": total / samples.size(), "p95_ms": samples[int(samples.size() * 0.95)], "frames": samples.size(), "grid": VoxelCodec.GRID, "tick": sim.tick, "sha256": initial_hash, "viewport": str(root.size), "scale": root.scaling_3d_scale}
				rows.append(row)
				print(JSON.stringify(row))
				if repeat == 0:
					await RenderingServer.frame_post_draw
					var err := root.get_texture().get_image().save_png(output + "/" + scene_name + "-" + row.variant + ".png")
					assert(err == OK)
		# Verify no hidden simulation writes changed the uploaded state.
		var result: Array[String] = []
		sim.request_readback(func(bytes: PackedByteArray): result.append(_sha(bytes)))
		var deadline := Time.get_ticks_msec() + 15000
		while result.is_empty() and Time.get_ticks_msec() < deadline:
			await process_frame
		if result.is_empty():
			push_error("Readback timed out; keep the GPU window visible")
			quit(1)
			return
		assert(result[0] == initial_hash, "Frozen world changed during rendering comparison")
		print("STATE_UNCHANGED ", scene_name, " ", initial_hash)
	var file := FileAccess.open(output + "/measurements.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t"))
	busy = false
