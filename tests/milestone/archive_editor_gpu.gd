extends SceneTree
## Exercise the real editor's authored/live boundary and GPU replacement path.
var editor: Node3D
var sim: Node3D
var panel: Node
var checks := 0
var failures := 0
var prior_time_input := true

func _initialize() -> void:
	create_timer(90.0).timeout.connect(func():
		push_error("Archive editor GPU watchdog expired")
		quit(1))
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", label])
	if not ok:
		failures += 1

func read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func wait_for_file() -> void:
	while panel.operation != "":
		await process_frame

func run() -> void:
	prior_time_input = root.get_node("TimeController").is_processing_unhandled_input()
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	sim.listen_to_time_controller = false
	panel = editor.archive_panel
	for i in 10:
		await RenderingServer.frame_post_draw
	var initial := await read()
	editor._begin_authored_edit()
	var n := VoxelCodec.GRID
	var centers: Array[Vector3i] = [Vector3i(n / 2, n * 3 / 4, n / 2)]
	sim.record_stroke(editor.active_transaction, centers, 2, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 42)
	editor._end_stroke()
	while editor.capturing:
		await process_frame
	var authored := await read()
	check(authored != initial and editor.undo_history.size() == 1, "real authored edit produces history and changed GPU bytes")
	var path := "user://archive-editor-gpu-%s.p3d" % Time.get_ticks_usec()
	panel.save_to_path(path)
	await wait_for_file()
	var saved: Dictionary = WorldArchive.load_authored(path, n)
	check(saved.ok and saved.bytes == authored, "Build save round-trips exact authored GPU bytes")
	editor.run_or_restore()
	while editor.capturing:
		await process_frame
	check(editor.testing and editor.build_snapshot == authored, "entering Test captures the authored revision")
	sim.request_ticks(12)
	var live := await read()
	check(live != authored, "the live experiment has actually evolved")
	panel.save_to_path(path)
	await wait_for_file()
	saved = WorldArchive.load_authored(path, n)
	check(saved.ok and saved.bytes == authored, "saving a running experiment preserves the authored construction")
	var old_epoch: int = sim.edit_epoch
	panel.open_path(path)
	await wait_for_file()
	check(not editor.testing and root.get_node("TimeController").paused, "opening returns the editor to paused Build")
	check(sim.edit_epoch > old_epoch and sim.tick == 0, "opening starts a fresh world epoch and tick count")
	check(await read() == authored, "opening replaces the live world with exact saved construction")
	check(editor.undo_history.is_empty() and editor.undo_bytes == 0 and editor.build_snapshot.is_empty(), "opening clears history and the previous Test snapshot")
	check(not editor.capturing and not editor.painting and editor.active_transaction == -1, "opening leaves no active edit transaction")
	panel.open_path(path + ".missing")
	await wait_for_file()
	check(await read() == authored, "failed open leaves actual GPU state intact")
	var controller := root.get_node("TimeController")
	var tick_before: int = controller.tick
	panel._begin_modal()
	for key in [KEY_N, KEY_SPACE]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = true
		root.push_input(event, true)
	for i in 2:
		await process_frame
	check(controller.paused and controller.tick == tick_before, "modal input ownership blocks legacy time shortcuts in Build")
	panel._end_modal()
	panel.open_path(path)
	sim.set_live_emitter(centers[0], 1, Elements.Id.SAND)
	sim.finish_live_emitter()
	await wait_for_file()
	check(panel.message.text.contains("changed"), "a completed newer live-source gesture invalidates an asynchronous Open")
	sim.clear_live_emitter()
	panel.open_path(path)
	sim.paint(centers[0] + Vector3i(8, 0, 0), 0, Elements.Id.WALL, sim.BrushMode.ONLY_AIR)
	await wait_for_file()
	check(await read() != authored and panel.message.text.contains("changed"), "asynchronous file open cannot overwrite a newer real GPU edit")
	var current := await read()
	check(not editor.replace_authored(PackedByteArray()) and await read() == current, "invalid replacement bytes are rejected without mutation")
	DirAccess.remove_absolute(path)
	editor.queue_free()
	await process_frame
	check(controller.is_processing_unhandled_input() == prior_time_input, "editor teardown restores previous legacy time input ownership")
	print("Archive editor GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
