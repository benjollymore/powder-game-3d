extends "res://tests/milestone/editor_workflow_gpu.gd"
## Repeated real-input Build/Undo/Redo/Test/Return cycles, with periodic file I/O.
## One visible process at a time. Snapshot checks are outside active-frame timing.
var duration := 120.0
var cycles: Array[Dictionary] = []
var session_started := 0
var baseline_memory: Dictionary = {}

func _initialize() -> void:
	output_dir = "/tmp/editor-session-soak"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("seconds="):
			duration = clampf(float(argument.trim_prefix("seconds=")), 5.0, 600.0)
		elif argument.begins_with("output_dir="):
			output_dir = argument.trim_prefix("output_dir=")
	create_timer(duration + 90.0).timeout.connect(func():
		push_error("Editor session soak watchdog expired")
		_restore_input()
		quit(1))
	call_deferred("run")

func memory_sample() -> Dictionary:
	var output: Array = []
	var rss_kib := -1
	if OS.get_name() == "macOS" and OS.execute("/bin/ps", ["-o", "rss=", "-p", str(OS.get_process_id())], output) == 0 and not output.is_empty():
		rss_kib = int(str(output[0]).strip_edges())
	return {"rss_kib": rss_kib, "godot_static_bytes": OS.get_static_memory_usage(),
		"renderer_video_bytes": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED),
		"history_bytes": editor.undo_bytes + editor.redo_bytes,
		"undo_entries": editor.undo_history.size(), "redo_entries": editor.redo_history.size()}

func write_result() -> void:
	var file := FileAccess.open(output_dir.path_join("result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"grid": VoxelCodec.GRID, "duration_s": duration,
		"baseline_memory": baseline_memory, "viewport_size": str(root.size),
		"engine": Engine.get_version_info().string, "vsync": DisplayServer.window_get_vsync_mode(),
		"render_scale": root.scaling_3d_scale, "render_mode": root.scaling_3d_mode,
		"aa": root.screen_space_aa, "checks": checks, "failures": failures, "cycles": cycles}, "  "))
	file.close()

func discard_temporary_edit() -> void:
	var guard: Node = editor.document_guard
	await frames(2)
	check(guard.state == "prompt", "dirty periodic Open requests explicit discard")
	if guard.state != "prompt":
		return
	var position: Vector2 = guard.discard_button.get_global_rect().get_center()
	if guard.dialog.is_embedded():
		position += Vector2(guard.dialog.position)
		move_to(position)
		await frames(1)
		mouse(true)
		await frames(1)
		mouse(false)
	else:
		var motion := InputEventMouseMotion.new()
		motion.window_id = guard.dialog.get_window_id()
		motion.position = position
		Input.parse_input_event(motion)
		for down in [true, false]:
			var event := InputEventMouseButton.new()
			event.window_id = motion.window_id
			event.position = position
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = down
			Input.parse_input_event(event)
			await frames(1)
	await frames(2)

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output_dir)
	original_cursor = DisplayServer.mouse_get_position()
	original_accumulation = Input.use_accumulated_input
	input_configured = true
	Input.use_accumulated_input = false
	editor = load("res://scenes/editor.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	clock = root.get_node("TimeController")
	await frames(30)
	var initial := await read()
	baseline_memory = memory_sample()
	print("EDITOR_SESSION_START ", JSON.stringify(baseline_memory))
	editor.radius_input.value = 1
	var n := VoxelCodec.GRID
	var first := Vector3i(n / 2, n * 3 / 4, n / 2)
	var last := first + Vector3i(n / 12, 0, 0)
	var live := first + Vector3i(0, n / 12, 0)
	session_started = Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - session_started) / 1e6 < duration and failures == 0:
		var cycle_started := Time.get_ticks_usec()
		await click(editor.material_buttons[Elements.Id.WALL])
		await stroke(first, last)
		var authored := await read()
		check(authored != initial and editor.undo_history.size() == 1, "cycle authored stroke has one transaction")
		await click(editor.undo_button)
		await settled()
		check(await read() == initial, "cycle Undo restores initial bytes")
		await click(editor.redo_button)
		await settled()
		check(await read() == authored, "cycle Redo restores authored bytes")
		await click(editor.play_button)
		await settled()
		check(editor.testing and not clock.paused, "cycle enters running Test")
		await click(editor.material_buttons[Elements.Id.SAND])
		move_to(point(live))
		await frames(2)
		mouse(true)
		var active_started := Time.get_ticks_usec()
		var previous := active_started
		var tick_before: int = sim.tick
		var intervals: Array[float] = []
		while Time.get_ticks_usec() - active_started < 600000:
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec()
			intervals.append(float(now - previous) / 1000.0)
			previous = now
		var active_ticks: int = sim.tick - tick_before
		mouse(false)
		await click(editor.pause_button)
		var paused_tick: int = sim.tick
		await frames(3)
		check(clock.paused and sim.tick == paused_tick, "cycle Pause stops authoritative ticks")
		await click(editor.step_button)
		check(clock.paused and sim.tick == paused_tick + 1, "cycle Step advances exactly once")
		await click(editor.play_button)
		await settled()
		check(not editor.testing and clock.paused and await read() == authored, "cycle Return restores exact authored bytes")
		await click(editor.undo_button)
		await settled()
		check(await read() == initial, "cycle authored history survives Test and returns to baseline")
		var archive_roundtrip := false
		if (cycles.size() + 1) % 10 == 0:
			var panel: Node = editor.archive_panel
			var path := output_dir.path_join("session-build.p3d")
			panel.save_to_path(path)
			while panel.operation != "":
				await process_frame
			await stroke(first, first)
			panel.open_path(path)
			while panel.operation != "":
				await process_frame
			await discard_temporary_edit()
			await settled()
			archive_roundtrip = await read() == initial and editor.undo_history.is_empty() and editor.redo_history.is_empty()
			check(archive_roundtrip, "periodic asynchronous Save/Open restores baseline and clears old history")
		intervals.sort()
		var total := 0.0
		for interval in intervals:
			total += interval
		var row := {"cycle": cycles.size() + 1,
			"elapsed_s": float(Time.get_ticks_usec() - session_started) / 1e6,
			"cycle_s": float(Time.get_ticks_usec() - cycle_started) / 1e6,
			"active_frames": intervals.size(), "active_mean_ms": total / intervals.size(),
			"active_p95_ms": intervals[mini(intervals.size() - 1, ceili(intervals.size() * 0.95) - 1)],
			"active_requested_ticks": active_ticks, "archive_roundtrip": archive_roundtrip,
			"memory": memory_sample()}
		cycles.append(row)
		print("EDITOR_SESSION_CYCLE ", JSON.stringify(row))
		write_result()
	check(not cycles.is_empty(), "session completed at least one cycle")
	write_result()
	await capture("final-build")
	_restore_input()
	editor.queue_free()
	await process_frame
	await process_frame
	print("Editor session soak: %d checks, %d failures; cycles=%d" % [checks, failures, cycles.size()])
	quit(1 if failures else 0)
