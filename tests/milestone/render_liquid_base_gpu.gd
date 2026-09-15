extends SceneTree
## Bright streaks at the base of a frozen liquid block on a slab. The block is
## uploaded with zero flags and never ticked, so the droplet/thin-spray path
## cannot run; the readback proves that. The streaks are the slab's underwater
## caustics seen through a liquid the volume pass treats as water-clear.
## A/B against immutable pre-change shaders: water (opacity 1) must stay
## byte-identical; lava (opacity 12) must lose the streaks with caustics on.
## godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_liquid_base_gpu.gd -- grid=128
const BASE_OPAQUE := "res://tests/milestone/fixtures/voxel_opaque_liquid_base_baseline.gdshader"
const BASE_VOLUME := "res://tests/milestone/fixtures/voxel_volume_liquid_base_baseline.gdshader"
const NEW_OPAQUE := "res://shaders/spatial/voxel_opaque.gdshader"
const NEW_VOLUME := "res://shaders/spatial/voxel_volume.gdshader"
var sim: Node3D
var camera: Camera3D
var checks := 0
var failures := 0
var rows: Array[Dictionary] = []
var out_dir := "res://docs/milestone/liquid-base-evidence/gpu"

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			out_dir = argument.trim_prefix("output_dir=")
	create_timer(170).timeout.connect(func(): push_error("Liquid base timeout"); quit(2))
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

func _fixture(id: int, lo: Vector3i, edge: int) -> PackedByteArray:
	var n := VoxelCodec.GRID
	var data := WorldBuilder.empty()
	for z in range(n / 8, n * 7 / 8):
		for y in range(lo.y - 3, lo.y):
			for x in range(n / 8, n * 7 / 8):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WALL, 0, 0)
	for z in range(lo.z, lo.z + edge):
		for y in range(lo.y, lo.y + edge):
			for x in range(lo.x, lo.x + edge):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, (x * 7 + y * 3 + z * 13) % 256, Elements.LIQUID_FULL)
	return data.to_byte_array()

func _flagged(bytes: PackedByteArray, lo: Vector3i, edge: int) -> int:
	var count := 0
	for z in range(lo.z, lo.z + edge):
		for y in range(lo.y, lo.y + edge):
			for x in range(lo.x, lo.x + edge):
				if (bytes[VoxelCodec.index(x, y, z) * 4 + 3] & 1) != 0:
					count += 1
	return count

func _screen_box(lo: Vector3i, edge: int) -> Rect2:
	var box := Rect2()
	var first := true
	for dz in [0, edge]:
		for dy in [0, edge]:
			for dx in [0, edge]:
				var p := camera.unproject_position(_world(Vector3(lo + Vector3i(dx, dy, dz))))
				if first:
					box = Rect2(p, Vector2.ZERO)
					first = false
				else:
					box = box.expand(p)
	return box.intersection(Rect2(Vector2.ZERO, Vector2(root.size)))

## Streak pixels: in the lower half of the block's screen box, pixels brighter
## than that band's median luminance by more than 0.12. Caustic ripples are
## sparse bright lines, so a median is a robust local reference.
func _streaks(img: Image, box: Rect2) -> int:
	var y0 := int(box.position.y + box.size.y * 0.5)
	var y1 := int(box.end.y)
	var x0 := int(box.position.x)
	var x1 := int(box.end.x)
	var lum: Array[float] = []
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := img.get_pixel(x, y)
			lum.append(0.299 * c.r + 0.587 * c.g + 0.114 * c.b)
	if lum.is_empty():
		return 0
	var sorted := lum.duplicate()
	sorted.sort()
	var median: float = sorted[sorted.size() / 2]
	var count := 0
	for v in lum:
		if v > median + 0.12:
			count += 1
	return count

func _capture(baseline: bool, caustic: float) -> Image:
	var mesh: ShaderMaterial = sim.get_node("Mesh").material_override
	var volume: ShaderMaterial = sim.get_node("VolumeMesh").material_override
	mesh.shader = load(BASE_OPAQUE if baseline else NEW_OPAQUE)
	volume.shader = load(BASE_VOLUME if baseline else NEW_VOLUME)
	sim.set_param("physical_overflow", sim._physical_overflow_texture)
	sim.set_param("caustic_strength", caustic)
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(480, 480)
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
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.6
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	var to_sun := Vector3(0.4, 1.0, 0.3).normalized()
	sun.shadow_enabled = false
	stage.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP)
	sim.set_param("light_dir", to_sun)
	sim.set_param("detail_strength", 0.18)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	for i in 20:
		await process_frame
	var s := float(VoxelCodec.GRID) / 128.0
	var n := VoxelCodec.GRID
	var lo := Vector3i(n / 2 - n / 16, n / 4, n / 2 - n / 16)
	var edge := n / 8
	var views := {
		"front": [Vector3(64, 46, 165), Vector3(64, 36, 64)],
		"oblique": [Vector3(130, 80, 140), Vector3(64, 34, 64)],
	}
	for liquid in [Elements.Id.WATER, Elements.Id.LAVA]:
		var name: String = Elements.TABLE[liquid].name.to_lower()
		var bytes := _fixture(liquid, lo, edge)
		sim.upload(bytes)
		for i in 6:
			await process_frame
		var uploaded: PackedByteArray = await _read()
		_check(uploaded == bytes, "%s block uploads exactly" % name)
		_check(_flagged(uploaded, lo, edge) == 0, "%s block has no falling flags, so the droplet and thin-spray paths cannot apply" % name)
		for view in views:
			camera.position = _world(views[view][0] * s)
			camera.look_at(_world(views[view][1] * s), Vector3.UP)
			var box := _screen_box(lo, edge)
			var images := {}
			for variant in ["baseline", "candidate"]:
				for caustic in [1.0, 0.0]:
					var img := await _capture(variant == "baseline", caustic)
					var key := "%s-%s" % [variant, "caustic" if caustic > 0.5 else "nocaustic"]
					images[key] = img
					_check(img.save_png(out_dir + "/%s-%s-%s.png" % [name, view, key]) == OK, "%s %s %s capture saved" % [name, view, key])
					var row := {"liquid": name, "view": view, "variant": variant, "caustic": caustic, "streaks": _streaks(img, box), "box_area": int(box.get_area())}
					rows.append(row)
					print(JSON.stringify(row))
			var b_on: int = rows[rows.size() - 4].streaks
			var b_off: int = rows[rows.size() - 3].streaks
			var c_on: int = rows[rows.size() - 2].streaks
			var c_off: int = rows[rows.size() - 1].streaks
			if liquid == Elements.Id.WATER:
				_check(images["baseline-caustic"].get_data() == images["candidate-caustic"].get_data(), "water %s renders byte-identically (opacity 1 keeps caustics)" % view)
				_check(images["baseline-nocaustic"].get_data() == images["candidate-nocaustic"].get_data(), "water %s without caustics renders byte-identically" % view)
			else:
				_check(b_on >= 3 * maxi(b_off, 1) and b_on > 40, "lava %s baseline streaks come from caustics (%d with, %d without)" % [view, b_on, b_off])
				_check(c_on <= maxi(int(1.5 * b_off), 20), "lava %s candidate keeps streaks at the no-caustic level with caustics on (%d vs %d)" % [view, c_on, b_off])
				_check(absi(c_on - c_off) <= maxi(b_off, 20), "lava %s candidate is insensitive to caustic_strength (%d vs %d)" % [view, c_on, c_off])
		var after: PackedByteArray = await _read()
		_check(after == bytes, "%s physical bytes unchanged across captures" % name)
	var file := FileAccess.open(out_dir + "/liquid-base-metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "\t"))
	file.close()
	print("LIQUID_BASE_CHECKS %d FAILURES %d" % [checks, failures])
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if failures else 0)
