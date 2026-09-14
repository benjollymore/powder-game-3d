extends SceneTree
## Deterministic flat-surface normal/coverage regression, with pre-fix A/B fixture.
## godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_surface_gpu.gd -- grid=128
const BASELINE := preload("res://tests/milestone/fixtures/voxel_opaque_baseline.gdshader")
const FIXED := preload("res://shaders/spatial/voxel_opaque.gdshader")
var sim: Node3D
var camera: Camera3D
var stage: Node3D
var failures := 0
var checks := 0
var rows: Array[Dictionary] = []
var out_dir := "res://docs/milestone/rendering-evidence"

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(1200, 900)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	stage = Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	stage.add_child(sim)
	sim.get_node("VolumeMesh").visible = false # these fixtures contain only solid cells
	camera = Camera3D.new()
	camera.near = 0.001
	camera.fov = 55.0
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLACK
	world.environment.ambient_light_energy = 0.0
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	for i in 30:
		await process_frame
	var cases: Array[Dictionary] = [
		{"name": "floor-oblique", "lo": Vector3i(8,16,8), "hi": Vector3i(120,20,120), "axis": 1, "plane": 20, "section": false, "camera": Vector3(0.82,0.50,0.90)},
		{"name": "floor-reverse", "lo": Vector3i(8,16,8), "hi": Vector3i(120,20,120), "axis": 1, "plane": 20, "section": false, "camera": Vector3(-0.90,0.70,0.42)},
		{"name": "floor-grazing", "lo": Vector3i(8,16,8), "hi": Vector3i(120,20,120), "axis": 1, "plane": 20, "section": false, "camera": Vector3(0.75,-0.18,1.10)},
		{"name": "single-cell-sheet", "lo": Vector3i(8,32,8), "hi": Vector3i(120,33,120), "axis": 1, "plane": 33, "section": false, "camera": Vector3(0.72,0.50,0.80)},
		{"name": "section-x", "lo": Vector3i(20,16,20), "hi": Vector3i(108,100,108), "axis": 0, "plane": 64, "section": true, "camera": Vector3(1.00,0.50,0.70)},
		{"name": "section-y", "lo": Vector3i(20,16,20), "hi": Vector3i(108,100,108), "axis": 1, "plane": 64, "section": true, "camera": Vector3(0.70,1.00,0.50)},
		{"name": "section-z", "lo": Vector3i(20,16,20), "hi": Vector3i(108,100,108), "axis": 2, "plane": 64, "section": true, "camera": Vector3(0.70,0.50,1.00)}
	]
	for c in cases:
		var bytes := _world(c)
		sim.upload(bytes)
		sim.set_param("section_enabled", c.section)
		sim.set_param("section_axis", c.axis)
		sim.set_param("section_cell", _cell(c.plane) - 1)
		camera.position = c.camera * sim.world_size()
		var target := Vector3.ZERO
		target[c.axis] = (float(c.plane) / 128.0 - 0.5) * sim.world_size()
		camera.look_at(target, Vector3.UP)
		var results: Array[Dictionary] = []
		for baseline in [true, false]:
			var mat: ShaderMaterial = sim.get_node("Mesh").material_override
			mat.shader = BASELINE if baseline else FIXED
			sim.set_param("debug_mode", 8)
			sim.set_param("detail_strength", 0.0)
			for i in 20:
				await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			var row := _measure(img, c)
			row["variant"] = "baseline" if baseline else "fixed"
			row["case"] = c.name
			rows.append(row)
			results.append(row)
			print(JSON.stringify(row))
			_check(img.save_png(out_dir + "/" + c.name + "-" + row.variant + "-normals.png") == OK, "capture " + c.name + " " + row.variant)
			if not baseline:
				_check(row.samples > 3000, c.name + " has a substantial visible analytic surface sample")
				_check(row.missing == 0, c.name + " has complete interior surface coverage")
				_check(row.wrong_normals == 0, c.name + " has constant correct flat-surface normals")
		if c.name == "floor-oblique" or c.name.begins_with("section-"):
			_check(results[0].wrong_normals > 0, c.name + " baseline reproduces the diagnosed defect")
		var after: PackedByteArray = await _read()
		_check(after == bytes, c.name + " GPU physical bytes unchanged across both views")
	var report := FileAccess.open(out_dir + "/surface-metrics.json", FileAccess.WRITE)
	report.store_string(JSON.stringify(rows, "\t"))
	report.close()
	print("SURFACE_CHECKS %d FAILURES %d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _cell(ref: int) -> int:
	return int(float(ref) * VoxelCodec.GRID / 128.0)

func _world(c: Dictionary) -> PackedByteArray:
	var d := WorldBuilder.empty()
	WorldBuilder.fill_box(d, Vector3i(c.lo) * VoxelCodec.GRID / 128, Vector3i(c.hi) * VoxelCodec.GRID / 128, Elements.Id.WALL)
	return d.to_byte_array()

func _measure(img: Image, c: Dictionary) -> Dictionary:
	var normal := Vector3.ZERO
	normal[c.axis] = 1.0
	var axes: Array[int] = []
	for a in 3:
		if a != c.axis:
			axes.append(a)
	var samples := 0
	var missing := 0
	var wrong := 0
	var max_error := 0.0
	for u in 96:
		for v in 96:
			var p := Vector3.ZERO
			p[c.axis] = float(c.plane)
			p[axes[0]] = lerpf(c.lo[axes[0]] + 6, c.hi[axes[0]] - 6, (u + 0.5) / 96.0)
			p[axes[1]] = lerpf(c.lo[axes[1]] + 6, c.hi[axes[1]] - 6, (v + 0.5) / 96.0)
			var pos := camera.unproject_position((p / 128.0 - Vector3.ONE * 0.5) * sim.world_size())
			var pixel := Vector2i(pos.floor())
			if pixel.x < 2 or pixel.y < 2 or pixel.x >= img.get_width() - 2 or pixel.y >= img.get_height() - 2:
				continue
			samples += 1
			var col := img.get_pixelv(pixel).srgb_to_linear()
			if maxf(col.r, maxf(col.g, col.b)) < 0.1:
				missing += 1
				continue
			var observed := Vector3(col.r, col.g, col.b) * 2.0 - Vector3.ONE
			var err := observed.distance_to(normal)
			max_error = maxf(max_error, err)
			if err > 0.08:
				wrong += 1
	return {"samples": samples, "missing": missing, "wrong_normals": wrong, "max_normal_error": max_error}

func _read() -> PackedByteArray:
	var result: Array[PackedByteArray] = []
	sim.request_readback(func(bytes: PackedByteArray): result.append(bytes))
	var deadline := Time.get_ticks_msec() + 15000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not result.is_empty(), "readback completes within 15 seconds")
	return PackedByteArray() if result.is_empty() else result[0]

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print(("ok: " if ok else "FAIL: ") + message)
