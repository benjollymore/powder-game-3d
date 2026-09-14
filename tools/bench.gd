extends SceneTree
## Visible whole-frame cost: runs the demo at maximum ticks per frame.
## Wall time includes rendering and scheduling; it is not isolated GPU time.
## Usage: godot --path . -s res://tools/bench.gd -- [frames] [hydro=0] [air=0] [ticks=N] [grid=N] [sunvis=0] [cam=x,y,z] [look=x,y,z] [aa=fxaa|smaa|temporal|spatial|off]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var frames := clampi(int(args[0]), 1, 3600) if args.size() > 0 and args[0].is_valid_int() else 180
	create_timer(180.0).timeout.connect(func():
		push_error("Benchmark watchdog: rendered frames did not complete")
		quit(1))
	var hydro := true
	var air := true
	var ticks := -1
	var cam := ""
	var look := ""
	var profile := false
	var aa := ""
	for a in args:
		if a == "hydro=0":
			hydro = false
		elif a == "air=0":
			air = false
		elif a.begins_with("ticks="):
			ticks = int(a.substr(6))
		elif a.begins_with("cam="):
			cam = a.substr(4)
		elif a.begins_with("look="):
			look = a.substr(5)
		elif a == "profile=1":
			profile = true
		elif a.begins_with("aa="):
			aa = a.substr(3)
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	if aa != "":
		load("res://tools/screenshot.gd").apply_aa(root.get_viewport(), aa)
	var sim := current_scene.get_node("SimVolume")
	sim.hydro_enabled = hydro
	sim.air_enabled = air
	sim.profile = profile
	var tc := root.get_node("TimeController")
	if ticks >= 0:
		tc.MAX_TICKS_PER_FRAME = ticks
	if cam != "":
		var rig := current_scene.get_node("CameraRig")
		var c := cam.split(",")
		rig.frame_position = Vector3(float(c[0]), float(c[1]), float(c[2])) * rig.world_size
		if look != "":
			var l := look.split(",")
			rig.orbit_target = Vector3(float(l[0]), float(l[1]), float(l[2])) * rig.world_size
		rig.frame_box(false)
	tc.time_scale = tc.MAX_SCALE
	for i in 30:
		await RenderingServer.frame_post_draw
	var total_ticks := 0
	var drawn_before := Engine.get_frames_drawn()
	var t0 := Time.get_ticks_usec()
	for i in frames:
		await RenderingServer.frame_post_draw
		total_ticks += tc.ticks_this_frame
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
	# Wall-clock per frame is the only reliable number on Metal (the viewport GPU
	# timer reads zero); run with --disable-vsync so the display cap does not hide cost.
	print("bench grid=%d hydro=%s air=%s ticks/frame=%.1f: %.2f ms/frame (%.0f fps)" % [
		VoxelCodec.GRID, hydro, air, float(total_ticks) / frames, ms, 1000.0 / ms])
	print("visible frames drawn: ", Engine.get_frames_drawn() - drawn_before)
	if profile:
		var rep: Dictionary = await sim.profile_report()
		print("GPU_TIMESTAMP_REPORT ", JSON.stringify(rep))
	sim.listen_to_time_controller = false
	tc.paused = true
	await RenderingServer.frame_post_draw
	current_scene.queue_free()
	await process_frame
	await process_frame
	quit(0)
