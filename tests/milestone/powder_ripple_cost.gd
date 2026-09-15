extends SceneTree
## Paired frame-interval cost of the smoothed-material opaque shading change on a
## frozen 256 sand heap plus reservoir. Alternates the immutable pre-fix shader
## and the candidate. Wall intervals only; no device timestamp or TPS claim.
## godot --path . --always-on-top --disable-vsync -s res://tests/milestone/powder_ripple_cost.gd -- grid=256
signal ready_result(value: Variant)
var sim: Node3D
var out := "res://docs/milestone/powder-ripple-evidence/cost"

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			out = argument.trim_prefix("output_dir=")
	root.get_node("TimeController").paused = true
	create_timer(150).timeout.connect(func(): push_error("Powder ripple cost timeout"); quit(2))
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(900, 700)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
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
	camera.position = Vector3(0.6, 0.45, 0.7) * sim.world_size()
	camera.look_at(Vector3(0.0, -0.1, 0.0) * sim.world_size())
	camera.near = 0.001
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.7
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = false
	stage.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -Vector3(0.4, 1.0, 0.3).normalized(), Vector3.UP)
	for i in 20: await process_frame
	var n := VoxelCodec.GRID
	var s := float(n) / 128.0
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i.ZERO, Vector3i(n, int(4 * s), n), Elements.Id.WALL)
	var sand := 0
	for y in range(int(4 * s), int(100 * s)):
		var radius := (100.0 * s - y) * 0.62
		for z in range(int(8 * s), int(120 * s)):
			for x in range(int(8 * s), int(120 * s)):
				if Vector2(x - 64 * s, z - 64 * s).length() < radius:
					data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.SAND, WorldBuilder.seed_at(x, y, z))
					sand += 1
	var water := 0
	for z in range(int(96 * s), int(124 * s)):
		for y in range(int(4 * s), int(28 * s)):
			for x in range(int(4 * s), int(124 * s)):
				if data[VoxelCodec.index(x, y, z)] == 0:
					data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WATER, 17, 200)
					water += 1
	var bytes := data.to_byte_array()
	sim.upload(bytes)
	for i in 10: await process_frame
	var shaders := {}
	for variant in ["original", "candidate"]:
		var shader := Shader.new()
		shader.code = FileAccess.get_file_as_string("res://tests/milestone/fixtures/voxel_opaque_ripple_baseline.gdshader" if variant == "original" else "res://shaders/spatial/voxel_opaque.gdshader")
		shaders[variant] = shader
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var rows: Array[Dictionary] = []
	var captures := {}
	for repeat in 3:
		for variant in (["original", "candidate"] if repeat % 2 == 0 else ["candidate", "original"]):
			sim.get_node("Mesh").material_override.shader = shaders[variant]
			sim.set_param("physical_overflow", sim._physical_overflow_texture)
			for i in 30: await process_frame
			var times: Array[float] = []
			var previous := Time.get_ticks_usec()
			for i in 120:
				await RenderingServer.frame_post_draw
				var now := Time.get_ticks_usec()
				times.append((now - previous) / 1000.0)
				previous = now
				await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			image.save_png(out + "/%s-%d.png" % [variant, repeat])
			captures[variant] = image.get_data()
			times.sort()
			var row := {"variant": variant, "repeat": repeat, "grid": n, "sand_cells": sand, "water_cells": water, "frame_median_ms": times[60], "frame_p95_ms": times[114], "frame_mean_ms": times.reduce(func(a, b): return a + b, 0.0) / times.size(), "native_scale": root.scaling_3d_scale, "screen_space_aa": root.screen_space_aa, "paused": true}
			rows.append(row)
			print(JSON.stringify(row))
	RenderingServer.call_on_render_thread(func(): ready_result.emit.call_deferred(sim._rd.texture_get_data(sim._grid_rid, 0)))
	var after: PackedByteArray = await ready_result
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(after)
	var changed := 0
	var max_delta := 0
	for i in captures.original.size():
		var delta := absi(captures.original[i] - captures.candidate[i])
		if delta != 0: changed += 1
		max_delta = maxi(max_delta, delta)
	var result := {"measurements": rows, "physical_state_exact": after == bytes, "voxel_sha256": hash.finish().hex_encode(), "capture_changed_bytes": changed, "capture_max_channel_difference": max_delta, "note": "frame-post-draw wall intervals, not device timestamps; always-on-top, VSync off; captures are expected to differ on sand"}
	var file := FileAccess.open(out + "/cost.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	print(JSON.stringify(result))
	print("POWDER_RIPPLE_COST failures=%d" % (0 if after == bytes else 1))
	quit(0 if after == bytes else 1)
