extends SceneTree
var editor: Node3D
var sim: Node3D
var checks := 0
var failures := 0

func _initialize() -> void:
	create_timer(90.0).timeout.connect(func():
		push_error("Editor action GPU watchdog expired")
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

func settled() -> void:
	while editor.capturing or not editor._queued_editor_action.is_empty():
		await process_frame
	await process_frame

func begin_stroke() -> void:
	editor._begin_authored_edit()
	editor.painting = true
	var centers: Array[Vector3i] = [Vector3i.ONE * (VoxelCodec.GRID / 2)]
	sim.record_stroke(editor.active_transaction, centers, 2, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 42)

func run() -> void:
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	editor.set_process(false)
	sim = editor.sim
	sim.listen_to_time_controller = false
	for i in 10:
		await RenderingServer.frame_post_draw
	var original := await read()
	begin_stroke()
	editor.undo_edit()
	check(editor._queued_editor_action == "undo" and not editor.painting, "Undo ends the stroke and retains the action while history is pending")
	await settled()
	check(await read() == original and editor.undo_history.is_empty(), "queued Undo restores exact GPU bytes after the capture completes")
	begin_stroke()
	editor.run_or_restore()
	check(editor._queued_editor_action == "start_test", "Run requested during capture retains its intended phase")
	await settled()
	check(editor.testing and editor.build_snapshot != original, "queued Run starts with the completed authored stroke")
	var build: PackedByteArray = editor.build_snapshot
	sim.request_ticks(6)
	await read()
	editor.run_or_restore()
	check(not editor.testing and await read() == build, "Return restores the exact construction captured by queued Run")
	editor.undo_edit()
	await settled()
	check(await read() == original, "authored Undo still applies after Run and Return")
	begin_stroke()
	editor.new_empty_build()
	editor.reset_container()
	check(editor._queued_editor_action == "reset", "latest explicit replacement supersedes an older queued action")
	await settled()
	check(editor.document_guard.state == "prompt", "queued dirty Reset waits for an explicit discard choice")
	editor.document_guard._discard()
	await settled()
	check(await read() == original and not editor.testing, "queued Reset produces the fresh container without replaying Empty afterward")
	editor.selection_toggle.button_pressed = true
	editor.new_empty_build()
	var empty := PackedByteArray()
	empty.resize(original.size())
	check(await read() == empty and not editor.selecting and editor.undo_bytes == 0, "Empty build resets GPU state, selection mode and history")
	editor.run_or_restore()
	sim.upload(original)
	await settled()
	check(not editor.testing and await read() == original, "stale Run readback cannot activate a replaced world")
	editor.run_or_restore()
	editor.reset_container()
	await settled()
	check(not editor.testing and root.get_node("TimeController").paused and await read() == original, "Reset requested during Run preparation is carried through to paused Build")
	var epoch_before: int = sim.edit_epoch
	editor.run_or_restore()
	editor.run_or_restore()
	await settled()
	check(editor.testing and sim.edit_epoch == epoch_before and editor.build_snapshot == original, "two Run requests during capture start one experiment instead of toggling back")
	editor.run_or_restore()
	editor.run_or_restore()
	editor.run_or_restore()
	sim.upload(original)
	await settled()
	check(not editor.testing and await read() == original, "queued phase intent cannot start a newly replaced world")
	print("Editor actions GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
