extends SceneTree
## GPU cost of the simulation: runs the demo world at the maximum ticks per
## frame and prints the average measured GPU frame time.
## Usage: godot --path . -s res://tools/bench.gd -- [frames] [hydro=0] [air=0] [ticks=N] [grid=N] [sunvis=0] [cam=x,y,z] [look=x,y,z] [aa=fxaa|smaa|temporal|spatial|off]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var frames := int(args[0]) if args.size() > 0 else 180
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
		await process_frame
	var total_ticks := 0
	var t0 := Time.get_ticks_usec()
	for i in frames:
		await process_frame
		total_ticks += tc.ticks_this_frame
	var ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
	# Wall-clock per frame is the only reliable number on Metal (the viewport GPU
	# timer reads zero); run with --disable-vsync so the display cap does not hide cost.
	print("bench grid=%d hydro=%s air=%s ticks/frame=%.1f: %.2f ms/frame (%.0f fps)" % [
		VoxelCodec.GRID, hydro, air, float(total_ticks) / frames, ms, 1000.0 / ms])
	if profile:
		var rep: Dictionary = sim.profile_report()
		var parts := PackedStringArray()
		for k in rep:
			parts.append("%s %.2f" % [k, rep[k]])
		print("gpu ms: " + "  ".join(parts))
	quit(0)
