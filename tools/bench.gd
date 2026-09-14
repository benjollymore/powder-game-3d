extends SceneTree
## GPU cost of the simulation: runs the demo world at the maximum ticks per
## frame and prints the average measured GPU frame time.
## Usage: godot --path . -s res://tools/bench.gd -- [frames] [hydro=0] [air=0] [ticks=N] [grid=N]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var frames := int(args[0]) if args.size() > 0 else 180
	var hydro := true
	var air := true
	var ticks := -1
	for a in args:
		if a == "hydro=0":
			hydro = false
		elif a == "air=0":
			air = false
		elif a.begins_with("ticks="):
			ticks = int(a.substr(6))
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var sim := current_scene.get_node("SimVolume")
	sim.hydro_enabled = hydro
	sim.air_enabled = air
	var tc := root.get_node("TimeController")
	if ticks >= 0:
		tc.MAX_TICKS_PER_FRAME = ticks
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
	quit(0)
