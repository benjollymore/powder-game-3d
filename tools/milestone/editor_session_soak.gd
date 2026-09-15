extends "res://tests/milestone/editor_workflow_gpu.gd"
## Repeated real-input Build/Undo/Redo/Test/Return cycles under the ordinary
## editor and TimeController process loops, with retained authored history and
## periodic file phases driven by parsed Cmd/Ctrl shortcuts and real dialog
## input. One visible process at a time. Snapshot checks and file I/O are
## outside active-frame timing. Native chooser selections arrive through the
## FileDialog signals, not physical OS input.
const PHASE_EVERY := 5
var duration := 120.0
var cycles: Array[Dictionary] = []
var session_started := 0
var baseline_memory: Dictionary = {}
var file_phases: Array[Dictionary] = []
var successful_saves := 0
var initial: PackedByteArray
# Controlled-variant opt-outs; the default is the complete new workload.
var held_source := true
var water_dot := true
var initial_path := ""
var build_path := ""

func _initialize() -> void:
	output_dir = "/tmp/editor-session-soak"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("seconds="):
			duration = clampf(float(argument.trim_prefix("seconds=")), 5.0, 600.0)
		elif argument.begins_with("output_dir="):
			output_dir = argument.trim_prefix("output_dir=")
		elif argument == "source=0":
			held_source = false
		elif argument == "water=0":
			water_dot = false
	create_timer(duration + 120.0).timeout.connect(func():
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
		"aa": root.screen_space_aa, "refresh_hz": DisplayServer.screen_get_refresh_rate(root.get_window().current_screen),
		"variant": {"held_source": held_source, "water_dot": water_dot}, "scheduler": {"target_ticks_per_second": clock.TICKS_PER_SECOND,
		"max_ticks_per_frame": clock.MAX_TICKS_PER_FRAME}, "phase_every": PHASE_EVERY,
		"successful_saves": successful_saves, "file_phases": file_phases,
		"checks": checks, "failures": failures, "cycles": cycles}, "  "))
	file.close()

# --- parsed shortcuts and dialog input -----------------------------------------

func command(code: int, meta := true, shift := false, down := true) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.meta_pressed = meta
	event.ctrl_pressed = not meta
	event.shift_pressed = shift
	event.pressed = down
	Input.parse_input_event(event)

func shortcut(code: int, meta := true, shift := false) -> void:
	command(code, meta, shift)
	command(code, meta, shift, false)

func finish_file_selection(path: String, opening := false) -> void:
	# Supply the native chooser's answer before its OS window would open.
	var panel: Node = editor.archive_panel
	panel.queued_dialog = ""
	panel._begin_modal()
	if opening:
		panel.open_dialog.file_selected.emit(path)
	else:
		panel.save_dialog.file_selected.emit(path)

func saved() -> void:
	var panel: Node = editor.archive_panel
	while panel.queued_dialog == "save_current" or panel.operation != "" or editor.capturing:
		await process_frame
	await frames(2)

func file_idle() -> void:
	var panel: Node = editor.archive_panel
	while panel.operation != "" or panel.queued_dialog != "" or editor.capturing:
		await process_frame
	await frames(2)

func guard_settled() -> void:
	var guard: Node = editor.document_guard
	var panel: Node = editor.archive_panel
	while guard.state != "" or panel.operation != "" or panel.queued_dialog != "" or editor.capturing:
		await process_frame
	await settled()

func dialog_key(code: int) -> void:
	var guard: Node = editor.document_guard
	var event := InputEventKey.new()
	event.window_id = guard.dialog.get_window_id()
	event.keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await frames(2)

func dialog_choice(button: Button) -> void:
	# Embedded dialogs share root input coordinates. Native subwindows own an
	# explicit window ID; both are real dialog input, not a direct method call.
	var guard: Node = editor.document_guard
	var position: Vector2 = button.get_global_rect().get_center()
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

func open_with_prompt(path: String, meta: bool) -> bool:
	var guard: Node = editor.document_guard
	await settled()
	shortcut(KEY_O, meta)
	finish_file_selection(path, true)
	await file_idle()
	check(guard.state == "prompt", "dirty periodic Open requests explicit discard")
	return guard.state == "prompt"

func file_phase(index: int, first: Vector3i) -> Dictionary:
	# Alternate the Command and Control forms of every shortcut between phases.
	var meta := index % 2 == 0
	var guard: Node = editor.document_guard
	var panel: Node = editor.archive_panel
	var temp := first + Vector3i(0, -6, 0)
	var n := VoxelCodec.GRID
	var record := {"phase": index, "modifier": "meta" if meta else "ctrl", "cancel": false,
		"save_first": false, "discard": false, "save_as": false, "named_save": false}
	# A: Save As moves the accumulated build to its own file.
	await settled()
	var accumulated := await read()
	shortcut(KEY_S, meta, true)
	check(panel.queued_dialog == "save", "phase Save As shortcut requests a path for the named build")
	finish_file_selection(build_path)
	await saved()
	record.save_as = editor.document.path == build_path and not editor.document.is_dirty() and WorldArchive.load_authored(build_path, n).bytes == accumulated
	check(record.save_as, "phase Save As writes the exact accumulated build and switches the active file")
	# B: a dirty Open answered with Cancel keeps the dirty construction.
	await stroke(temp, temp)
	var dirty := await read()
	check(dirty != accumulated and editor.document.is_dirty(), "phase temporary stroke makes the named build dirty")
	if await open_with_prompt(initial_path, meta):
		await dialog_key(KEY_ESCAPE)
		await guard_settled()
		record.cancel = guard.state.is_empty() and await read() == dirty and editor.document.is_dirty() and editor.document.path == build_path
		check(record.cancel, "phase Cancel in the unsaved-build dialog preserves the dirty construction and file")
	# C: a dirty Open answered with Save writes the current file, then opens.
	if await open_with_prompt(initial_path, meta):
		await dialog_choice(guard.dialog.get_ok_button())
		await guard_settled()
		record.save_first = WorldArchive.load_authored(build_path, n).bytes == dirty and await read() == initial and not editor.document.is_dirty() and editor.document.path == initial_path and editor.undo_history.is_empty() and editor.redo_history.is_empty()
		check(record.save_first, "phase Save in the unsaved-build dialog saves the dirty build exactly, then opens the requested file")
	# D: a dirty Open answered with Discard drops the temporary stroke.
	await stroke(temp, temp)
	check(editor.document.is_dirty() and await read() != initial, "phase second temporary stroke dirties the reopened initial build")
	if await open_with_prompt(initial_path, meta):
		await dialog_choice(guard.discard_button)
		await guard_settled()
		record.discard = await read() == initial and not editor.document.is_dirty() and editor.document.path == initial_path and editor.undo_history.is_empty() and editor.redo_history.is_empty()
		check(record.discard, "phase Discard in the unsaved-build dialog restores the requested file and clears history")
	# E: a named Save shortcut writes the current file without a chooser.
	var saves_before := successful_saves
	shortcut(KEY_S, meta)
	check(panel.queued_dialog == "save_current" or panel.operation != "", "phase named Save shortcut saves directly without a chooser")
	await saved()
	record.named_save = successful_saves == saves_before + 1 and not editor.document.is_dirty() and WorldArchive.load_authored(initial_path, n).bytes == initial
	check(record.named_save, "phase named Save shortcut rewrites the exact initial build once")
	file_phases.append(record)
	return record

# --- session ----------------------------------------------------------------------

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
	var panel: Node = editor.archive_panel
	panel.save_finished.connect(func(ok, _token, _generation):
		if ok: successful_saves += 1)
	await frames(30)
	initial = await read()
	baseline_memory = memory_sample()
	print("EDITOR_SESSION_START ", JSON.stringify(baseline_memory))
	var n := VoxelCodec.GRID
	var first := Vector3i(n / 2, n * 3 / 4, n / 2)
	var live := first + Vector3i(0, n / 12, 0)
	var water := first + Vector3i(-n / 8, 0, 0)
	check(id_at(initial, water) == Elements.Id.AIR, "water dot target starts as isolated air")
	initial_path = output_dir.path_join("initial.p3d")
	build_path = output_dir.path_join("session-build.p3d")
	# The untitled build's first Save goes through the chooser path once.
	shortcut(KEY_S)
	check(panel.queued_dialog == "save", "untitled session Save shortcut requests a path")
	finish_file_selection(initial_path)
	await saved()
	check(editor.document.path == initial_path and not editor.document.is_dirty() and WorldArchive.load_authored(initial_path, n).bytes == initial, "untitled session Save writes the exact initial build")
	var base := initial
	var in_phase := 0
	session_started = Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - session_started) / 1e6 < duration and failures == 0:
		var cycle_started := Time.get_ticks_usec()
		var history_before: int = editor.undo_history.size()
		var stroke_at := first + Vector3i(0, 3 * in_phase, 0)
		editor.radius_input.value = 1
		await click(editor.material_buttons[Elements.Id.WALL])
		await stroke(stroke_at, stroke_at + Vector3i(n / 12, 0, 0))
		var walled := await read()
		check(walled != base and editor.undo_history.size() == history_before + 1, "cycle authored stroke has one transaction")
		# A paused radius-zero water click is the ordinary thin-liquid case: an
		# isolated nonfalling cell that the volume shader must still show.
		var water_at := water + Vector3i(0, 3 * in_phase, 0)
		var transactions := 1
		if water_dot:
			transactions = 2
			editor.radius_input.value = 0
			await click(editor.material_buttons[Elements.Id.WATER])
			await stroke(water_at, water_at)
		var authored := await read()
		if water_dot:
			check(id_at(base, water_at) == Elements.Id.AIR and id_at(authored, water_at) == Elements.Id.WATER and editor.undo_history.size() == history_before + 2 and clock.paused, "cycle paused radius-zero water click is a second transaction that lands as Water")
		if cycles.is_empty():
			await capture("first-cycle-build")
		for i in transactions:
			await click(editor.undo_button)
			await settled()
		check(await read() == base, "cycle Undo restores initial bytes")
		for i in transactions:
			await click(editor.redo_button)
			await settled()
		check(await read() == authored, "cycle Redo restores authored bytes")
		await click(editor.play_button)
		await settled()
		check(editor.testing and not clock.paused, "cycle enters running Test")
		editor.radius_input.value = 1
		await click(editor.material_buttons[Elements.Id.SAND])
		move_to(point(live))
		await frames(2)
		if held_source:
			mouse(true)
		var active_started := Time.get_ticks_usec()
		var previous := active_started
		var tick_before: int = sim.tick
		var intervals: Array[float] = []
		var cap_frames := 0
		while Time.get_ticks_usec() - active_started < 600000:
			await RenderingServer.frame_post_draw
			var now := Time.get_ticks_usec()
			intervals.append(float(now - previous) / 1000.0)
			previous = now
			if clock.ticks_this_frame >= clock.MAX_TICKS_PER_FRAME:
				cap_frames += 1
		var active_seconds := float(Time.get_ticks_usec() - active_started) / 1e6
		var active_ticks: int = sim.tick - tick_before
		if held_source:
			mouse(false)
		check(active_ticks > 0 and editor.testing, "cycle normal scheduling advanced authoritative ticks while a live source was held")
		await click(editor.pause_button)
		var paused_tick: int = sim.tick
		await frames(3)
		check(clock.paused and sim.tick == paused_tick, "cycle Pause stops authoritative ticks")
		await click(editor.step_button)
		check(clock.paused and sim.tick == paused_tick + 1, "cycle Step advances exactly once")
		await click(editor.play_button)
		await settled()
		check(not editor.testing and clock.paused and await read() == authored, "cycle Return restores exact authored bytes")
		for i in transactions:
			await click(editor.undo_button)
			await settled()
		check(await read() == base, "cycle authored history survives Test and returns to baseline")
		for i in transactions:
			await click(editor.redo_button)
			await settled()
		check(await read() == authored and editor.undo_history.size() == history_before + transactions and editor.redo_history.is_empty(), "cycle Redo retains accumulated authored history across cycles")
		base = authored
		in_phase += 1
		var archive_roundtrip := false
		var phase: Dictionary = {}
		if in_phase % PHASE_EVERY == 0:
			phase = await file_phase(file_phases.size() + 1, first)
			archive_roundtrip = phase.save_as and phase.cancel and phase.save_first and phase.discard and phase.named_save
			check(archive_roundtrip, "periodic asynchronous Save/Open restores baseline and clears old history")
			base = initial
			in_phase = 0
		intervals.sort()
		var total := 0.0
		for interval in intervals:
			total += interval
		var row := {"cycle": cycles.size() + 1,
			"elapsed_s": float(Time.get_ticks_usec() - session_started) / 1e6,
			"cycle_s": float(Time.get_ticks_usec() - cycle_started) / 1e6,
			"active_frames": intervals.size(), "active_mean_ms": total / intervals.size(),
			"active_p95_ms": intervals[mini(intervals.size() - 1, ceili(intervals.size() * 0.95) - 1)],
			"active_requested_ticks": active_ticks, "active_seconds": active_seconds,
			"achieved_ticks_per_second": active_ticks / active_seconds, "cap_frames": cap_frames,
			"retained_undo_entries": editor.undo_history.size(),
			"archive_roundtrip": archive_roundtrip, "file_phase": phase,
			"memory": memory_sample()}
		cycles.append(row)
		print("EDITOR_SESSION_CYCLE ", JSON.stringify(row))
		write_result()
	check(not cycles.is_empty(), "session completed at least one cycle")
	check(file_phases.is_empty() or file_phases.all(func(p): return p.cancel and p.save_first and p.discard), "every file phase answered the unsaved-build dialog with Save, Discard and Cancel")
	write_result()
	await capture("final-build")
	_restore_input()
	editor.queue_free()
	await process_frame
	await process_frame
	print("Editor session soak: %d checks, %d failures; cycles=%d; file phases=%d" % [checks, failures, cycles.size(), file_phases.size()])
	quit(1 if failures else 0)
