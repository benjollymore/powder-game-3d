extends SceneTree
## Alternating paused reservoir frame intervals. No device timestamp or TPS claim.
signal ready_result(value: Variant)
var sim: Node3D
var failures := 0
var OUT := "res://docs/milestone/ordinary-liquid-evidence/cost"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): OUT = arg.trim_prefix("output_dir=")
	root.get_node("TimeController").paused = true
	create_timer(300).timeout.connect(func(): push_error("Ordinary liquid cost timeout"); quit(2))
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(900,700)
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
	camera.position = Vector3(0.6,0.45,0.7)*sim.world_size()
	camera.look_at(Vector3.ZERO)
	camera.near = 0.001
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.7
	stage.add_child(world)
	for i in 20: await process_frame
	var n := VoxelCodec.GRID
	var y_lo := 3*n/8
	var y_hi := 5*n/8
	var fixtures := {}
	# uniform-200: every cell nominal full (the original measurement). hydro-compressed:
	# what hydro.glsl:106 leaves in a settled reservoir, FULL + COMP * cells_above,
	# capped at MAX_AMOUNT (255); only the surface row is exactly 200 there.
	for fixture in ["uniform-200","hydro-compressed"]:
		var data := WorldBuilder.empty()
		var count := 0
		for z in range(n/4,3*n/4):
			for y in range(y_lo,y_hi):
				for x in range(n/4,3*n/4):
					var amount := 200 if fixture=="uniform-200" else mini(200+2*(y_hi-1-y),255)
					data[VoxelCodec.index(x,y,z)] = VoxelCodec.encode(Elements.Id.WATER,17,amount)
					count += 1
		fixtures[fixture] = {"bytes":data.to_byte_array(),"count":count}
	var shaders := {}
	for variant in ["original","candidate"]:
		var shader := Shader.new()
		shader.code = FileAccess.get_file_as_string("res://docs/milestone/ordinary-liquid-evidence/original/voxel_volume.gdshader.txt" if variant=="original" else "res://shaders/spatial/voxel_volume.gdshader")
		shaders[variant] = shader
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var rows: Array[Dictionary] = []
	var summary := {"measurements":rows,"fixtures":{},"note":"frame-post-draw wall intervals, not device timestamps; always-on-top, VSync off; paired original/candidate medians only"}
	for fixture in fixtures:
		var bytes: PackedByteArray = fixtures[fixture].bytes
		var count: int = fixtures[fixture].count
		sim.upload(bytes)
		for i in 10: await process_frame
		var captures := {}
		for repeat in 3:
			for variant in (["original","candidate"] if repeat%2==0 else ["candidate","original"]):
				sim.get_node("VolumeMesh").material_override.shader = shaders[variant]
				sim.set_param("physical_overflow",sim._physical_overflow_texture)
				for i in 30: await process_frame
				var times: Array[float] = []
				var previous := Time.get_ticks_usec()
				for i in 120:
					await RenderingServer.frame_post_draw
					var now := Time.get_ticks_usec()
					times.append((now-previous)/1000.0)
					previous = now
					await process_frame
				await RenderingServer.frame_post_draw
				var image := root.get_texture().get_image()
				image.save_png(OUT+"/%s-%s-%d.png"%[fixture,variant,repeat])
				captures[variant] = image.get_data()
				times.sort()
				var row := {"fixture":fixture,"variant":variant,"repeat":repeat,"grid":n,"physical_cells":count,"frame_median_ms":times[60],"frame_p95_ms":times[114],"frame_mean_ms":times.reduce(func(a,b): return a+b,0.0)/times.size(),"native_scale":root.scaling_3d_scale,"screen_space_aa":root.screen_space_aa,"paused":true}
				rows.append(row)
				print(JSON.stringify(row))
		RenderingServer.call_on_render_thread(func(): ready_result.emit.call_deferred(sim._rd.texture_get_data(sim._grid_rid,0)))
		var after: PackedByteArray = await ready_result
		var hash := HashingContext.new()
		hash.start(HashingContext.HASH_SHA256); hash.update(after)
		var wrong_bytes := 0
		var max_channel_difference := 0
		for i in captures.original.size():
			var delta := absi(captures.original[i]-captures.candidate[i])
			if delta!=0: wrong_bytes += 1
			max_channel_difference = maxi(max_channel_difference,delta)
		summary.fixtures[fixture] = {"physical_state_exact":after==bytes,"voxel_sha256":hash.finish().hex_encode(),"capture_changed_bytes":wrong_bytes,"capture_max_channel_difference":max_channel_difference}
		if after!=bytes: failures += 1
	var result := summary
	var file := FileAccess.open(OUT+"/cost.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(result,"\t")); file.close()
	print(JSON.stringify(result))
	print("ORDINARY_LIQUID_COST failures=%d"%failures)
	quit(0 if failures==0 else 1)
