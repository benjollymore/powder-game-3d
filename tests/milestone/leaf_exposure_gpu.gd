extends SceneTree
## Leaf cards must not clip under the editor presentation. A plant bank beside
## water is captured at a grazing angle with the real editor lighting (filmic
## tonemap, ambient 0.65, sun 1.0), and the fraction of leaf-band pixels whose
## green channel is clipped is measured for the pinned pre-change shader and for
## the current one. The baseline must clip and the candidate must not, so the
## gate is shown to detect the defect rather than merely passing.
signal ready_result(value: Variant)
var sim: Node3D
var out_dir := "res://docs/milestone/leaf-exposure-evidence"
var checks := 0
var failures := 0
## Green at or above this (of 255) is clipped for our purposes.
const CLIP := 235
## Measured on this fixture: the pinned pre-change shader clips 41.1% of the
## leaf band, the current one 8.6%, with mean band green 214 -> 179. The
## thresholds sit either side of that with headroom for driver variation; the
## residual 8.6% is the brightest sun-facing cards, which is a real highlight.
const CANDIDATE_MAX_PCT := 12.0
const BASELINE_MIN_PCT := 30.0
## Mean green the band must keep, so the fix cannot be "make leaves dark".
const DULL_MIN_GREEN := 150.0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): out_dir = arg.trim_prefix("output_dir=")
	root.get_node("TimeController").paused = true
	create_timer(300).timeout.connect(func(): push_error("Leaf exposure timeout"); quit(2))
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FAIL: " + message)
	print(("ok: " if ok else "FAIL: ") + message)


func _read() -> PackedByteArray:
	RenderingServer.call_on_render_thread(func(): ready_result.emit.call_deferred(sim._rd.texture_get_data(sim._grid_rid, 0)))
	return await ready_result


## Mean green in the band: the guard against fixing clipping by going dull.
func _mean_green(image: Image, y0: int, y1: int, x0: int, x1: int) -> float:
	var total := 0.0
	var count := 0
	for y in range(y0, y1):
		for x in range(x0, x1):
			total += image.get_pixel(x, y).g * 255.0
			count += 1
	return total / float(maxi(count, 1))


## Fraction of pixels in the leaf band whose green channel is clipped.
func _clipped_pct(image: Image, y0: int, y1: int, x0: int, x1: int) -> float:
	var total := 0
	var clipped := 0
	for y in range(y0, y1):
		for x in range(x0, x1):
			var c := image.get_pixel(x, y)
			total += 1
			if int(round(c.g * 255.0)) >= CLIP:
				clipped += 1
	return 100.0 * float(clipped) / float(maxi(total, 1))


func _run() -> void:
	root.size = Vector2i(900, 500)
	root.scaling_3d_scale = 1.0
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA # the editor default
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
	stage.add_child(world)
	for i in 24: await process_frame

	# The real editor presentation: this is the lighting the defect appears under.
	var EditorPresentation := load("res://scripts/render/editor_presentation.gd")
	EditorPresentation.apply(sim, world, stage)
	await process_frame

	var n := VoxelCodec.GRID
	var floor_top := 8
	var bank_top := floor_top + 10
	var data := WorldBuilder.empty()
	for z in range(0, n):
		for x in range(0, n):
			for y in range(0, floor_top):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WALL, 11, 0)
	# Water in front, a plant bank behind it: the bank's top face is air, so every
	# top cell grows leaf cards, which is the growth front's steady state.
	for z in range(4, n - 4):
		for x in range(4, n - 4):
			var plant_here := z < n / 2
			# A ragged top, as a real growth front has, so cards sit at many
			# heights and overlap the way the reported frame shows.
			var h := 0
			if plant_here:
				var g := (x * 73856093) ^ (z * 19349663)
				g = (g >> 13) ^ g
				h = absi(g) % 4
			for y in range(floor_top, bank_top + h):
				var id := Elements.Id.PLANT if plant_here else Elements.Id.WATER
				var amount := 0 if plant_here else 200
				if not plant_here and y >= bank_top: continue
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, 11, amount)
	sim.upload(data.to_byte_array())
	for i in 24: await process_frame

	var world_size: float = sim.world_size()
	var cell: float = world_size / float(n)
	var surf := bank_top * cell - world_size * 0.5
	camera.position = Vector3(0.0, surf + 7.0 * cell, 10.0 * cell)
	camera.look_at(Vector3(0.0, surf + 3.0 * cell, -50.0 * cell))
	camera.near = 0.001
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	for i in 12: await process_frame

	var before := await _read()
	var leaves: MultiMeshInstance3D = sim.get_node("Leaves")
	var material: ShaderMaterial = leaves.material_override
	var current: Shader = material.shader
	var baseline := Shader.new()
	baseline.code = FileAccess.get_file_as_string("res://tests/milestone/fixtures/leaf_exposure_baseline.gdshader")

	# The leaf band only: the cards fill the lower half of the frame, the sky the
	# upper. Measuring the sky would dilute the fraction into meaninglessness.
	var y0 := int(root.size.y * 0.50)
	var y1 := int(root.size.y * 0.92)
	var x0 := int(root.size.x * 0.10)
	var x1 := int(root.size.x * 0.90)
	var pct := {}
	var mean := {}
	for variant in ["baseline", "candidate"]:
		# The ShaderMaterial keeps its parameters across a shader swap: both
		# shaders declare the same uniforms.
		material.shader = baseline if variant == "baseline" else current
		for i in 8: await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		_check(image.save_png(out_dir + "/leaf-band-%s.png" % variant) == OK, "%s capture saved" % variant)
		pct[variant] = _clipped_pct(image, y0, y1, x0, x1)
		mean[variant] = _mean_green(image, y0, y1, x0, x1)
		print("LEAF_CLIP %s %.1f%% mean_green %.0f" % [variant, pct[variant], mean[variant]])
	material.shader = current
	for i in 6: await process_frame

	_check(pct["baseline"] >= BASELINE_MIN_PCT,
			"pinned pre-change leaf shader clips the band (%.1f%% >= %.1f%%), so the gate detects the defect" % [pct["baseline"], BASELINE_MIN_PCT])
	_check(pct["candidate"] <= CANDIDATE_MAX_PCT,
			"current leaf shader keeps the band unclipped (%.1f%% <= %.1f%%)" % [pct["candidate"], CANDIDATE_MAX_PCT])
	_check(pct["candidate"] < pct["baseline"],
			"the change reduces clipping (%.1f%% < %.1f%%)" % [pct["candidate"], pct["baseline"]])
	_check(mean["candidate"] >= DULL_MIN_GREEN,
			"leaves stay bright rather than dull (mean green %.0f >= %.0f)" % [mean["candidate"], DULL_MIN_GREEN])
	_check(await _read() == before, "leaf shading leaves every physical byte unchanged")
	print("LEAF_EXPOSURE_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
