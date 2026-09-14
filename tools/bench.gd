extends SceneTree
## GPU cost of the simulation: runs the demo world at the maximum ticks per
## frame and prints the average measured GPU frame time.
## Usage: godot --path . -s res://tools/bench.gd -- [frames] [hydro=0|1]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var frames := int(args[0]) if args.size() > 0 else 180
	var hydro := true
	for a in args:
		if a == "hydro=0":
			hydro = false
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	var sim := current_scene.get_node("SimVolume")
	sim.hydro_enabled = hydro
	var tc := root.get_node("TimeController")
	tc.time_scale = tc.MAX_SCALE
	var vp := root.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp, true)
	for i in 30:
		await process_frame
	var gpu := 0.0
	var cpu := 0.0
	var ticks := 0
	for i in frames:
		await process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		ticks += tc.ticks_this_frame
	print("bench hydro=%s: %.2f ms GPU, %.2f ms CPU per frame, %.1f ticks/frame, FPS %d" % [
		hydro, gpu / frames, cpu / frames, float(ticks) / frames, Engine.get_frames_per_second()])
	quit(0)
