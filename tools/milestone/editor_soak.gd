extends SceneTree
## Normal editor + TimeController scheduling, visible frames, and exact Return.
## Run one visible GPU process at a time. Default VSync represents ordinary play.
## -- grid=128 seconds=20 scenario=Demo output_dir=/tmp/editor-soak
var seconds := 20.0
var scenario := "bowl"
var output_dir := "/tmp/editor-soak"
var surface_hover := false
var quality := "editor"
var original_cursor := Vector2i.ZERO
var cursor_moved := false
var surface_requests := 0
var surface_hit_frames := 0
var last_surface_request := -1
var editor: Node3D
var sim: Node3D
var clock: Node
var intervals: Array[float] = []
var windows: Array[Dictionary] = []
var started := 0
var previous := 0
var window_started := 0
var window_tick := 0
var tick_start := 0
var window_first_sample := 0
var cap_frames := 0

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("seconds="):
			seconds = clampf(float(argument.trim_prefix("seconds=")), 2.0, 600.0)
		elif argument.begins_with("scenario="):
			scenario = argument.trim_prefix("scenario=")
		elif argument.begins_with("output_dir="):
			output_dir = argument.trim_prefix("output_dir=")
		elif argument == "surface_hover=1":
			surface_hover = true
		elif argument.begins_with("quality="):
			quality = argument.trim_prefix("quality=")
	create_timer(seconds + 90.0).timeout.connect(func():
		_restore_cursor()
		push_error("Editor soak watchdog")
		quit(1))
	call_deferred("run")

func _restore_cursor() -> void:
	if cursor_moved:
		DisplayServer.warp_mouse(original_cursor - DisplayServer.window_get_position(root.get_window_id()))
		cursor_moved = false

func read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func digest(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()

func summarize(samples: Array[float]) -> Dictionary:
	var sorted := samples.duplicate()
	sorted.sort()
	var sum := 0.0
	for sample in samples:
		sum += sample
	return {"frames": samples.size(), "mean_ms": sum / samples.size(),
		"p95_ms": sorted[mini(sorted.size() - 1, ceili(sorted.size() * 0.95) - 1)],
		"max_ms": sorted.back()}

func memory() -> Dictionary:
	return {"godot_static_bytes": OS.get_static_memory_usage(),
		"renderer_video_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
		"renderer_texture_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED),
		"renderer_buffer_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED)}

func close_window(now: int) -> void:
	var row := summarize(intervals.slice(window_first_sample))
	row["elapsed_s"] = float(now - started) / 1e6
	row["ticks_per_second"] = float(sim.tick - window_tick) * 1e6 / float(now - window_started)
	row["memory"] = memory()
	windows.append(row)
	print("EDITOR_SOAK_WINDOW ", JSON.stringify(row))
	window_started = now
	window_tick = sim.tick
	window_first_sample = intervals.size()

func run() -> void:
	if quality not in ["editor", "project", "native-fxaa", "native-smaa", "metalfx-fxaa"]:
		push_error("Unknown soak quality")
		quit(1)
		return
	if quality not in ["editor", "project"]:
		root.scaling_3d_scale = 0.75 if quality == "metalfx-fxaa" else 1.0
		root.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL if quality == "metalfx-fxaa" else Viewport.SCALING_3D_MODE_BILINEAR
		root.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA if quality == "native-smaa" else Viewport.SCREEN_SPACE_AA_FXAA
	if scenario != "bowl" and scenario not in Scenarios.names():
		push_error("Unknown soak scenario")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(output_dir)
	editor = load("res://scenes/editor.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	clock = root.get_node("TimeController")
	if scenario != "bowl":
		sim.load_scenario(scenario)
	editor.yaw = 0.65
	editor.pitch = -0.4
	editor._update_camera()
	for i in 30:
		await RenderingServer.frame_post_draw
	if surface_hover:
		# This workload exercises ordinary valid surface picks. The default cut
		# cap can correctly reject outward placement beyond its visible slab.
		editor._set_section(false)
		editor._set_target_mode(editor.TargetMode.SURFACE)
		original_cursor = DisplayServer.mouse_get_position()
		var pointer: Vector2 = editor.camera.unproject_position(sim.global_position + Vector3(0.0, -0.3, 0.0) * sim.world_size())
		Input.warp_mouse(pointer)
		var motion := InputEventMouseMotion.new()
		motion.position = pointer
		motion.global_position = pointer
		Input.parse_input_event(motion)
		cursor_moved = true
	var authored := await read()
	var initial_memory := memory()
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output_dir.path_join("authored.png"))
	editor.run_or_restore()
	while editor.capturing:
		await process_frame
	if not editor.testing:
		_restore_cursor()
		push_error("Soak could not enter Test")
		quit(1)
		return
	print("EDITOR_SOAK_CONFIG ", JSON.stringify({"grid": VoxelCodec.GRID, "scenario": scenario,
		"resolution": str(root.size), "seconds": seconds,
		"quality": quality, "render_scale": root.scaling_3d_scale,
		"render_scaling_mode": root.scaling_3d_mode, "screen_space_aa": root.screen_space_aa,
		"surface_hover": surface_hover,
		"section_enabled": editor.section,
		"vsync_mode": DisplayServer.window_get_vsync_mode(), "target_tps": clock.TICKS_PER_SECOND,
		"max_ticks_per_frame": clock.MAX_TICKS_PER_FRAME, "deferred_preparation": sim.defer_render_preparation,
		"initial_memory": initial_memory, "authored_sha256": digest(authored)}))
	# Hashing/configuration output must precede warmup: otherwise its CPU cost
	# becomes catch-up ticks in the first measured interval.
	for i in 60:
		await RenderingServer.frame_post_draw
	if surface_hover:
		print("EDITOR_SOAK_SURFACE ", JSON.stringify({"mouse": str(root.get_mouse_position()), "cache": editor.pick_cache}))
	started = Time.get_ticks_usec()
	previous = started
	window_started = started
	window_tick = sim.tick
	tick_start = sim.tick
	var drawn_start := Engine.get_frames_drawn()
	while float(Time.get_ticks_usec() - started) / 1e6 < seconds:
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		intervals.append(float(now - previous) / 1000.0)
		previous = now
		if surface_hover:
			if editor.last_pick_ms != last_surface_request:
				last_surface_request = editor.last_pick_ms
				surface_requests += 1
			if editor.pick_cache.get("valid", false):
				surface_hit_frames += 1
		if clock.ticks_this_frame == clock.MAX_TICKS_PER_FRAME:
			cap_frames += 1
		if now - window_started >= 2000000:
			close_window(now)
	var finished := Time.get_ticks_usec()
	var final_tick: int = sim.tick
	var frames_drawn := Engine.get_frames_drawn() - drawn_start
	clock.paused = true
	if window_first_sample < intervals.size():
		close_window(finished)
	var final_bytes := await read()
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output_dir.path_join("experiment.png"))
	editor.run_or_restore()
	while editor.capturing:
		await process_frame
	var restored := await read()
	var ok: bool = not editor.testing and clock.paused and restored == authored and frames_drawn >= intervals.size()
	if surface_hover:
		ok = ok and surface_requests > 1 and surface_hit_frames > 0
	var result := summarize(intervals)
	result["wall_s"] = float(finished - started) / 1e6
	result["ticks"] = final_tick - tick_start
	result["achieved_tps"] = float(final_tick - tick_start) / result.wall_s
	result["target_tps"] = clock.TICKS_PER_SECOND
	result["cap_frames"] = cap_frames
	result["surface_requests"] = surface_requests
	result["surface_hit_frames"] = surface_hit_frames
	result["frames_drawn"] = frames_drawn
	result["authored_return_exact"] = restored == authored
	result["experiment_sha256"] = digest(final_bytes)
	result["final_memory"] = memory()
	result["windows"] = windows
	var file := FileAccess.open(output_dir.path_join("result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("EDITOR_SOAK_RESULT ", JSON.stringify(result))
	print("Editor soak: 1 checks, %d failures" % [0 if ok else 1])
	_restore_cursor()
	editor.queue_free()
	await process_frame
	await process_frame
	quit(0 if ok else 1)
