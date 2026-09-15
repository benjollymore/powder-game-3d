extends SceneTree
## Every example through the real editor: load it with Examples, capture the
## authored build, press Run, capture a frame per simulated second, Return and
## require exact authored restoration of voxels and temperatures. Writes an
## index.json of frames with per-scenario tick rate and mean frame interval.
## Timings are labelled not comparable unless taken on mains power with an
## idle GPU (see docs/milestone/status.md).
##   godot --path . --always-on-top --disable-vsync --resolution 1600x900 \
##     -s res://tools/milestone/capture_examples.gd -- grid=128 seconds=4 output_dir=/tmp/examples-capture
var editor: Node3D
var sim: Node3D
var output_dir := "/tmp/examples-capture"
var seconds := 4.0
var failures := 0
var scenarios := 0
var index := {}
var intervals: Array[float] = []
var last_draw_usec := 0
var timing := false

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("seconds="):
			seconds = clampf(float(argument.trim_prefix("seconds=")), 1.0, 60.0)
		elif argument.begins_with("output_dir="):
			output_dir = argument.trim_prefix("output_dir=")
	var budget := Scenarios.names().size() * (seconds * 3.0 + 12.0) + 20.0
	create_timer(budget).timeout.connect(func():
		push_error("Examples capture watchdog expired after %.0f s" % budget)
		write_index()
		quit(1))
	RenderingServer.frame_post_draw.connect(_drawn)
	call_deferred("run")

func _drawn() -> void:
	var now := Time.get_ticks_usec()
	if timing and last_draw_usec > 0:
		intervals.append(float(now - last_draw_usec) / 1000.0)
	last_draw_usec = now

func fail(message: String) -> void:
	failures += 1
	push_error(message)
	print("FAIL: " + message)

func ok(message: String) -> void:
	print("ok: " + message)

func draw_frames(count: int) -> void:
	for i in count:
		await RenderingServer.frame_post_draw

func settled() -> void:
	while editor.capturing or not editor._queued_editor_action.is_empty() or (is_instance_valid(editor.document_guard) and not editor.document_guard.state.is_empty()):
		await process_frame
	await process_frame

func read_world() -> Dictionary:
	var result: Array = []
	editor.read_world(func(voxels: PackedByteArray, thermal: PackedByteArray): result.append({"voxels": voxels, "thermal": thermal}))
	while result.is_empty():
		await process_frame
	return result[0]

func capture(name: String) -> String:
	await draw_frames(3)
	var image := root.get_texture().get_image()
	var path := output_dir.path_join(name + ".png")
	if image.is_empty() or image.save_png(path) != OK:
		fail("Could not capture " + path)
		return ""
	return name + ".png"

func slug(name: String) -> String:
	return name.to_lower().replace(" ", "-")

func power_mode() -> String:
	# Best effort: macOS Low Power Mode caps the display at 60 Hz and throttles
	# the SoC, which invalidates every timing below.
	var lines := []
	if OS.execute("pmset", ["-g"], lines) == 0:
		for line in String("\n".join(lines)).split("\n"):
			if line.strip_edges().begins_with("powermode"):
				return line.strip_edges()
	return "unknown"

func write_index() -> void:
	var file := FileAccess.open(output_dir.path_join("index.json"), FileAccess.WRITE)
	if file == null:
		return
	file.store_string(JSON.stringify({"grid": VoxelCodec.GRID, "seconds": seconds, "scenarios": index,
		"resolution": [root.size.x, root.size.y], "refresh_hz": DisplayServer.screen_get_refresh_rate(root.get_window().current_screen),
		"power_mode": power_mode(), "vsync": DisplayServer.window_get_vsync_mode(),
		"timing_note": "Tick rate and frame intervals are not comparable across runs unless taken on mains power with an idle GPU."}, "\t"))
	file.close()

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output_dir)
	root.size = Vector2i(1600, 900)
	editor = load(ProjectSettings.get_setting("application/run/main_scene")).instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	await draw_frames(20)
	var clock = root.get_node("TimeController")
	var ticks_per_second: float = float(clock.TICKS_PER_SECOND)
	Input.warp_mouse(Vector2(1500, 860)) # keep the brush marker out of the frame
	for name in Scenarios.names():
		scenarios += 1
		var key := slug(name)
		var entry := {"name": name, "frames": [], "restored": false}
		index[key] = entry
		editor.load_example(name)
		await settled()
		if editor.testing or editor.document.is_dirty():
			fail("%s: Examples did not produce a clean authored build" % name)
			continue
		var authored := await read_world()
		if authored.voxels != Scenarios.build(name):
			fail("%s: loaded build differs from Scenarios.build" % name)
		editor._set_section(false)
		editor.yaw = 0.65
		editor.pitch = -0.4
		editor._update_camera()
		var frame := await capture(key + "-build")
		if not frame.is_empty():
			entry.frames.append({"file": frame, "phase": "build", "sim_seconds": 0.0})
		# Run through the real button.
		editor.play_button.pressed.emit()
		await settled()
		if not editor.testing:
			fail("%s: Run did not enter Test" % name)
			continue
		editor.speed_slider.value = 0 # 1x
		var tick_start: int = sim.tick
		var wall_start := Time.get_ticks_usec()
		intervals.clear()
		last_draw_usec = 0
		timing = true
		var next_capture := 1
		var wall_limit := seconds * 3.0 + 8.0
		while true:
			await process_frame
			var sim_seconds := float(sim.tick - tick_start) / ticks_per_second
			var wall := float(Time.get_ticks_usec() - wall_start) / 1e6
			if sim_seconds >= float(next_capture) and next_capture <= int(seconds):
				timing = false
				var shot := await capture("%s-run-%02d" % [key, next_capture])
				timing = true
				last_draw_usec = 0
				if not shot.is_empty():
					entry.frames.append({"file": shot, "phase": "run", "sim_seconds": sim_seconds, "tick": sim.tick - tick_start})
				next_capture += 1
			if sim_seconds >= seconds or wall > wall_limit:
				break
		timing = false
		var ticks: int = sim.tick - tick_start
		var wall_seconds := float(Time.get_ticks_usec() - wall_start) / 1e6
		var mean := 0.0
		for interval in intervals:
			mean += interval
		mean = mean / intervals.size() if not intervals.is_empty() else 0.0
		entry["ticks"] = ticks
		entry["wall_seconds"] = wall_seconds
		entry["achieved_ticks_per_second"] = ticks / wall_seconds if wall_seconds > 0.0 else 0.0
		entry["mean_frame_ms"] = mean
		entry["frames_timed"] = intervals.size()
		entry["reached_target"] = float(ticks) / ticks_per_second >= seconds
		if not entry.reached_target:
			fail("%s: only %d ticks in %.1f s wall; target %.0f simulated seconds" % [name, ticks, wall_seconds, seconds])
		# Return through the real button and require exact restoration.
		editor.play_button.pressed.emit()
		await settled()
		var restored := await read_world()
		entry.restored = not editor.testing and restored.voxels == authored.voxels and restored.thermal == authored.thermal
		if entry.restored:
			ok("%s: Return restored exact authored voxels and temperatures after %d ticks" % [name, ticks])
		else:
			fail("%s: Return did not restore the authored build exactly (voxels %s, thermal %s)" % [name, restored.voxels == authored.voxels, restored.thermal == authored.thermal])
		var after := await capture(key + "-returned")
		if not after.is_empty():
			entry.frames.append({"file": after, "phase": "returned", "sim_seconds": 0.0})
		print("EXAMPLE ", JSON.stringify(entry))
	write_index()
	print("EXAMPLES_CAPTURE scenarios=%d failures=%d" % [scenarios, failures])
	editor.queue_free()
	await process_frame
	await process_frame
	quit(1 if failures else 0)
