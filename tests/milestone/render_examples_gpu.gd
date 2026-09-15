extends SceneTree
## Readability of the showcase scenarios under the editor presentation, A/B
## against immutable pre-change shaders and the previous palette overrides.
## Volcano: lava must read orange-red, not a saturated cream slab. Ice cave:
## the interior must not blow out to white and ice must read blue. Dam break
## (no heat, no ice) is the byte-identical control. Paused, physical bytes
## unchanged, captures saved for review.
## godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_examples_gpu.gd -- grid=128
const BASE_OPAQUE := "res://tests/milestone/fixtures/voxel_opaque_examples_baseline.gdshader"
const BASE_VOLUME := "res://tests/milestone/fixtures/voxel_volume_examples_baseline.gdshader"
const NEW_OPAQUE := "res://shaders/spatial/voxel_opaque.gdshader"
const NEW_VOLUME := "res://shaders/spatial/voxel_volume.gdshader"
var sim: Node3D
var camera: Camera3D
var checks := 0
var failures := 0
var rows: Array[Dictionary] = []
var out_dir := "res://docs/milestone/examples-look-evidence"
var candidate_palette: PackedColorArray
var baseline_palette: PackedColorArray

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			out_dir = argument.trim_prefix("output_dir=")
	create_timer(170).timeout.connect(func(): push_error("Examples look timeout"); quit(2))
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FAIL: " + message)
	else:
		print("ok: " + message)

func _read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func _world(cell: Vector3) -> Vector3:
	return (cell / float(VoxelCodec.GRID) - Vector3.ONE * 0.5) * sim.world_size()

## Pixel classes over the whole frame: blown-out white, saturated orange, blue.
func _classes(img: Image) -> Dictionary:
	var white := 0
	var orange := 0
	var blue := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > 0.85 and c.g > 0.85 and c.b > 0.85:
				white += 1
			if c.r > 0.85 and c.g > 0.25 and c.g < 0.8 and c.b < 0.55:
				orange += 1
			if c.b > 0.45 and c.b > c.r + 0.08:
				blue += 1
	return {"white": white, "orange": orange, "blue": blue}

func _mean_luminance(img: Image) -> float:
	var total := 0.0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			total += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
	return total / float((img.get_width() / 2) * (img.get_height() / 2))

func _capture(baseline: bool, old_palette: bool = baseline) -> Image:
	var mesh: ShaderMaterial = sim.get_node("Mesh").material_override
	var volume: ShaderMaterial = sim.get_node("VolumeMesh").material_override
	mesh.shader = load(BASE_OPAQUE if baseline else NEW_OPAQUE)
	volume.shader = load(BASE_VOLUME if baseline else NEW_VOLUME)
	sim.set_param("physical_overflow", sim._physical_overflow_texture)
	sim.set_param("palette", baseline_palette if old_palette else candidate_palette)
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(640, 480)
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
	camera.fov = 50.0
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	stage.add_child(world)
	for i in 10:
		await process_frame
	# The editor's own presentation (tonemap, sun, palette overrides, glow binding).
	load("res://scripts/render/editor_presentation.gd").apply(sim, world, stage)
	candidate_palette = sim.get_node("Mesh").material_override.get_shader_parameter("palette")
	# Pre-change presentation: the same overrides with the alpha-1 defaults that
	# the glow scaffold turned into self-illumination, and no ice override.
	baseline_palette = candidate_palette.duplicate()
	for id in [Elements.Id.WALL, Elements.Id.SAND, Elements.Id.WATER]:
		baseline_palette[id] = Color(baseline_palette[id].r, baseline_palette[id].g, baseline_palette[id].b, 1.0)
	if Elements.Id.has("ICE"):
		baseline_palette[Elements.Id.ICE] = Elements.palette()[Elements.Id.ICE]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	for i in 10:
		await process_frame
	var s := float(VoxelCodec.GRID) / 128.0
	var scenes := ["Dam break", "Volcano", "Ice cave"]
	for name: String in scenes:
		if not Scenarios.names().has(name):
			print("note: scenario %s absent; skipped" % name)
			continue
		var bytes: PackedByteArray = Scenarios.build(name)
		sim.upload(bytes)
		for i in 8:
			await process_frame
		camera.position = _world(Vector3(150, 110, 150) * s)
		camera.look_at(_world(Vector3(64, 40, 64) * s), Vector3.UP)
		var slug: String = name.to_lower().replace(" ", "-")
		var images := {}
		for variant in ["baseline", "candidate"]:
			var img := await _capture(variant == "baseline")
			images[variant] = img
			_check(img.save_png(out_dir + "/%s-%s.png" % [slug, variant]) == OK, "%s %s capture saved" % [name, variant])
			var row := _classes(img)
			row["scene"] = name
			row["variant"] = variant
			rows.append(row)
			print(JSON.stringify(row))
		var b: Dictionary = rows[rows.size() - 2]
		var c: Dictionary = rows[rows.size() - 1]
		match name:
			"Dam break":
				# No cell above 800 K and no ice: the shader change alone must be
				# invisible. The palette fix (overrides no longer self-illuminate)
				# is the only difference and is checked as a strict darkening.
				var same_palette := await _capture(false, true)
				_check(images["baseline"].get_data() == same_palette.get_data(), "Dam break renders byte-identically with the new shaders under the old palette")
				_check(c.white <= b.white and _mean_luminance(images["candidate"]) < _mean_luminance(images["baseline"]), "Dam break is darker, not brighter, once wall, sand and water stop self-illuminating")
			"Volcano":
				_check(b.white > 2000, "Volcano baseline reproduces the blown-out lava lake (%d white px)" % b.white)
				_check(c.white <= b.white / 4, "Volcano candidate removes the cream slab (%d -> %d white px)" % [b.white, c.white])
				_check(c.orange >= b.orange + 2000, "Volcano candidate lava reads orange (%d -> %d orange px)" % [b.orange, c.orange])
			"Ice cave":
				_check(b.white > 2000, "Ice cave baseline reproduces the white interior (%d white px)" % b.white)
				_check(c.white <= b.white / 2, "Ice cave candidate halves the blown-out area (%d -> %d white px)" % [b.white, c.white])
				_check(c.blue >= b.blue + 2000, "Ice cave candidate ice reads blue (%d -> %d blue px)" % [b.blue, c.blue])
		var after: PackedByteArray = await _read()
		_check(after == bytes, "%s physical bytes unchanged across captures" % name)
	var file := FileAccess.open(out_dir + "/examples-look-metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t"))
	file.close()
	print("EXAMPLES_LOOK_CHECKS %d FAILURES %d" % [checks, failures])
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if failures else 0)
