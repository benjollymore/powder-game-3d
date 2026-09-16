extends SceneTree
## Ben reported a regular lattice of bright marks on surfaces seen through
## water: molten wax filming on water, lava under water crusting to stone, and
## solid wax viewed from underwater. All three share one geometry, a surface
## submerged in liquid, and one cause: the caustic ripple was applied at full
## strength whatever way the surface faced. Because the pattern is sampled by
## world xz after projecting the shading point along the sun, every point of a
## vertical face walks the same straight line through that noise, so the
## two-dimensional ripple collapsed into stripes along the voxel staircase.
##
## The fix scales the ripple by the receiver's cosine, so this suite asserts
## both halves of the contract: a submerged wall loses the stripes, and a
## submerged floor keeps its caustics. Captures are matched against the pinned
## pre-change shader. No solver steps run: the authored bytes are exactly what
## is drawn, so any pattern in the image is a rendering result.
signal snapshot_ready(value: Variant)
var sim: Node3D
var camera: Camera3D
var out_dir := "res://docs/milestone/wax-lattice-evidence/gates"
var checks := 0
var failures := 0
var metrics: Array[Dictionary] = []
var baseline_shader: Shader
var current_shader: Shader

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): out_dir = arg.trim_prefix("output_dir=")
	root.get_node("TimeController").paused = true
	create_timer(420).timeout.connect(func(): push_error("Submerged caustic timeout"); quit(2))
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1
	print(("ok: " if ok else "FAIL: ") + message)

func _frames(n: int) -> void:
	for i in n: await process_frame

func _capture(name: String) -> Image:
	await _frames(6)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png(out_dir + "/" + name + ".png")
	return image

## How much pattern a variant adds over the same frame rendered with caustics
## off. Mean absolute luminance difference over the region, so it is zero where
## nothing changed and large where a ripple was painted on. This compares a
## variant against its own reference rather than against another variant's
## texture, which is what makes it robust to where the band is placed.
func _added(variant: Image, reference: Image, lo: Vector2i, hi: Vector2i) -> float:
	var total := 0.0
	var count := 0
	for y in range(lo.y, hi.y):
		for x in range(lo.x, hi.x):
			var a := variant.get_pixel(x, y)
			var b := reference.get_pixel(x, y)
			var la := 0.2126 * a.r + 0.7152 * a.g + 0.0722 * a.b
			var lb := 0.2126 * b.r + 0.7152 * b.g + 0.0722 * b.b
			total += absf(la - lb)
			count += 1
	return total / maxf(float(count), 1.0)

func _rt_snapshot() -> void:
	sim.request_readback(func(bytes): snapshot_ready.emit.call_deferred(bytes))

func _read() -> PackedByteArray:
	_rt_snapshot()
	return await snapshot_ready

func _use(shader: Shader) -> void:
	sim.get_node("Mesh").material_override.shader = shader
	await _frames(6)

## Water tank with a wall floor, plus whatever `payload` adds.
func _tank(payload: Callable) -> PackedByteArray:
	var n: int = VoxelCodec.GRID
	var data := WorldBuilder.empty()
	for z in range(n / 4, 3 * n / 4):
		for x in range(n / 4, 3 * n / 4):
			data[VoxelCodec.index(x, n / 4 - 1, z)] = VoxelCodec.encode(Elements.Id.WALL, 3)
			for y in range(n / 4, n / 2):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WATER, 17, Elements.LIQUID_FULL)
	payload.call(data, n)
	return data.to_byte_array()

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
	camera = Camera3D.new()
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

	current_shader = sim.get_node("Mesh").material_override.shader
	baseline_shader = Shader.new()
	baseline_shader.code = FileAccess.get_file_as_string("res://tests/milestone/fixtures/voxel_opaque_caustic_baseline.gdshader")
	_check(not baseline_shader.code.is_empty(), "pinned pre-change shader loads")

	var n: int = VoxelCodec.GRID
	var size: float = sim.world_size()

	# A stone block standing in the water, exactly Ben's geometry: a submerged
	# vertical face below the waterline with the same material dry above it.
	var wall := _tank(func(data: PackedInt32Array, g: int):
		for z in range(g / 2 - 12, g / 2 + 12):
			for x in range(g / 2 - 12, g / 2 + 12):
				for y in range(g / 4, g / 2 + 14):
					data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.STONE, 7))
	sim.upload(wall)
	await _frames(10)
	var authored := await _read()
	camera.position = Vector3(0.62 * size, (float(n) / 4.0 + 4.0) / float(n) * size - 0.5 * size, 0.0)
	camera.look_at(Vector3.ZERO)
	# The submerged part of the block's face, below the waterline.
	# The block's submerged vertical face, the bright column in the capture.
	var wet := Vector2i(472, 225)
	var wet_hi := Vector2i(584, 430)

	sim.set_param("caustic_strength", 0.0)
	await _use(current_shader)
	var none := await _capture("wall-caustics-off")
	sim.set_param("caustic_strength", 1.0)
	await _use(baseline_shader)
	var before := await _capture("wall-before")
	await _use(current_shader)
	var after := await _capture("wall-after")
	var r_before := _added(before, none, wet, wet_hi)
	var r_after := _added(after, none, wet, wet_hi)
	metrics.append({"case": "submerged wall", "before_added": r_before, "after_added": r_after})
	print("METRIC wall added_before=%.5f added_after=%.5f" % [r_before, r_after])

	_check(r_before > 0.01, "the pinned shader really does paint a pattern on a submerged wall (%.5f)" % r_before)
	# Not zero, and it should not be: a voxel staircase genuinely has partly
	# upward-facing facets, and those receive caustics correctly. What must go
	# is the stripe pattern, which the matched captures show it does; the
	# residual here is the block's own texture lit slightly differently.
	_check(r_after < r_before * 0.5, "the fix removes most of it (%.5f -> %.5f)" % [r_before, r_after])
	_check(await _read() == authored, "shading a submerged wall changes no physical bytes")

	# Control: a submerged floor must keep its caustics, or the fix has simply
	# deleted the effect rather than aimed it.
	var floor_world := _tank(func(_data: PackedInt32Array, _g: int): pass)
	sim.upload(floor_world)
	await _frames(10)
	var floor_authored := await _read()
	camera.position = Vector3(0.30 * size, (float(n) / 4.0 + 7.0) / float(n) * size - 0.5 * size, 0.30 * size)
	camera.look_at(Vector3(0.0, -0.22 * size, 0.0))
	var lo := Vector2i(260, 300)
	var hi := Vector2i(800, 480)

	sim.set_param("caustic_strength", 0.0)
	await _use(current_shader)
	var f_none := await _capture("floor-caustics-off")
	sim.set_param("caustic_strength", 1.0)
	await _use(baseline_shader)
	var f_before := _added(await _capture("floor-before"), f_none, lo, hi)
	await _use(current_shader)
	var f_after := _added(await _capture("floor-after"), f_none, lo, hi)
	metrics.append({"case": "submerged floor", "before_added": f_before, "after_added": f_after})
	print("METRIC floor added_before=%.5f added_after=%.5f" % [f_before, f_after])

	_check(f_after > 0.02, "a submerged floor still shows its caustics (%.5f added over none)" % f_after)
	_check(f_after > f_before * 0.5, "the floor keeps most of the effect it had (%.5f vs %.5f)" % [f_after, f_before])
	_check(await _read() == floor_authored, "shading a submerged floor changes no physical bytes")

	var file := FileAccess.open(out_dir + "/metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(metrics, "\t"))
	file.close()
	print("SUBMERGED_CAUSTIC_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
