extends SceneTree
## Production editor/history adapters; only frame painting is disabled to make
## authored commands and explicit simulation ticks deterministic.
var editor: Node3D
var sim: Node3D
var checks := 0
var failures := 0
var action_times: Array[int] = []
func _initialize() -> void:
	create_timer(90.0).timeout.connect(func():
		push_error("Editor Redo GPU watchdog expired")
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
func one(cell: Vector3i) -> Array[Vector3i]:
	return [cell]
func begin() -> int:
	editor._begin_authored_edit()
	return editor.active_transaction
func finish() -> void:
	editor._end_stroke()
	await settled()
func history(redo := false) -> void:
	var start := Time.get_ticks_usec()
	if redo:
		editor.redo_button.pressed.emit()
	else:
		editor.undo_button.pressed.emit()
	await settled()
	action_times.append(Time.get_ticks_usec() - start)
func totals() -> bool:
	var past := 0
	var future := 0
	for entry in editor.undo_history:
		past += entry.bytes
	for entry in editor.redo_history:
		future += entry.bytes
	return editor.undo_bytes == past and editor.redo_bytes == future and past + future <= 128 * 1024 * 1024
func run() -> void:
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	editor.set_process(false)
	sim = editor.sim
	sim.listen_to_time_controller = false
	for i in 10:
		await RenderingServer.frame_post_draw
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(32, 32, 32), Vector3i(33, 40, 40), Elements.Id.WALL)
	editor.replace_authored(data.to_byte_array())
	var original := await read()
	var id := begin()
	sim.record_stroke(id, one(Vector3i(31, 34, 34)), 1, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 42)
	sim.record_region(id, Vector3i(30, 33, 33), Vector3i(36, 36, 36), Elements.Id.WATER)
	sim.record_stroke(id, one(Vector3i(31, 34, 34)), 0, Elements.Id.AIR, sim.BrushMode.ERASE, 43)
	await finish()
	var authored := await read()
	check(authored != original and editor.undo_history.size() == 1, "mixed paint/region/erase creates one authored transaction")
	check(editor.undo_bytes == 12288 and editor.redo_bytes == 0, "mixed transaction retains two first-touch tiles (12288 bytes with thermal)")
	check(authored[VoxelCodec.index(32, 34, 34) * 4] == Elements.Id.WALL, "mixed additive painting preserves the container wall")
	await history()
	check(await read() == original and editor.undo_history.is_empty() and editor.redo_history.size() == 1,
		"Undo captures the inverse and restores every original packed byte")
	check(totals() and editor.redo_bytes == 12288, "Undo transfers the retained byte accounting to Redo, without doubling it")
	await history(true)
	check(await read() == authored and editor.redo_history.is_empty(), "Redo restores exact mixed authored bytes, seeds, amounts and flags")
	await history()
	check(await read() == original and totals(), "repeated reverse operation returns exactly to the original state")
	# This accepted stamp captures a tile but changes no voxel; Redo must survive.
	id = begin()
	sim.record_stroke(id, one(Vector3i(32, 34, 34)), 0, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 99)
	await finish()
	check(await read() == original and editor.undo_history.is_empty() and editor.redo_history.size() == 1,
		"occupied ONLY_AIR gesture is a verified no-op and preserves Redo")
	id = begin() # An empty/missed gesture has no touched region at all.
	await finish()
	check(editor.redo_history.size() == 1 and editor.undo_history.is_empty(), "missed gesture preserves Redo without a regional inspection")
	await history(true)
	check(await read() == authored, "Redo remains exact after occupied and missed no-op gestures")
	await history()
	# A real new edit branches history and clears only the old future.
	id = begin()
	sim.record_stroke(id, one(Vector3i(35, 34, 34)), 0, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 101)
	await finish()
	var branch := await read()
	check(editor.redo_history.is_empty() and editor.undo_history.size() == 1 and branch != original,
		"accepted changed authored edit clears the obsolete Redo chain")
	id = begin()
	sim.record_region(id, Vector3i(34, 35, 34), Vector3i(37, 37, 37), Elements.Id.WATER)
	await finish()
	var future := await read()
	await history()
	check(await read() == branch and editor.undo_history.size() == 1 and editor.redo_history.size() == 1 and totals(),
		"multiple edits retain contiguous past and future with one combined budget")
	# Preserve both directions through a real experiment and central reset.
	editor.run_or_restore()
	await settled()
	editor.toggle_test_pause()
	check(editor.testing and root.get_node("TimeController").paused, "history-bearing construction enters inspectable paused Test")
	sim.request_ticks(5)
	var runtime := await read()
	check(runtime != branch, "experiment advances real material before Return")
	editor.undo_edit()
	editor.redo_edit()
	check(editor.undo_history.size() == 1 and editor.redo_history.size() == 1, "Test cannot apply authored Undo or Redo")
	editor.run_or_restore()
	await settled()
	check(await read() == branch and totals(), "Return restores authored packed bytes and retains both history directions")
	await history(true)
	check(await read() == future, "Redo record epoch is correctly rebound after Return")
	await history()
	await history()
	check(await read() == original and editor.redo_history.size() == 2 and totals(), "Undo chain remains exact after Run/Return/Redo")
	# Reset/Open uses the same replacement API, and must clear both directions.
	editor.replace_authored(future)
	check(editor.undo_history.is_empty() and editor.redo_history.is_empty() and totals(), "Open/replacement clears both history stacks and byte totals")
	id = begin()
	sim.record_stroke(id, one(Vector3i(36, 34, 34)), 0, Elements.Id.SAND)
	await finish()
	editor.undo_edit()
	editor.new_empty_build()
	check(editor._queued_editor_action == "empty", "Empty requested during inverse capture remains queued")
	await settled()
	var empty := PackedByteArray()
	empty.resize(original.size())
	check(await read() == empty and editor.undo_history.is_empty() and editor.redo_history.is_empty() and totals(),
		"queued Empty executes after Undo and clears both directions")
	# A capture made obsolete before completion must not write into a new world.
	editor.replace_authored(original)
	id = begin()
	sim.record_stroke(id, one(Vector3i(35, 34, 34)), 0, Elements.Id.SAND)
	await finish()
	editor.undo_edit()
	sim.upload(future)
	await settled()
	check(await read() == future and editor.undo_history.is_empty() and editor.redo_history.is_empty(),
		"reset during inverse capture rejects stale restoration and clears unavailable history")
	if VoxelCodec.GRID >= 256:
		editor.replace_authored(original)
		id = begin()
		sim.record_stroke(id, one(Vector3i(35, 34, 34)), 0, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 202)
		var prefix := await read()
		sim.record_region(id, Vector3i.ZERO, Vector3i.ONE * VoxelCodec.GRID, Elements.Id.WATER)
		await finish()
		check(await read() == prefix and editor.undo_bytes == 6144 and not editor.edit_message.is_empty(),
			"over-cap region changes nothing, reports limit and retains only accepted prefix history")
		await history()
		check(await read() == original, "partial accepted transaction remains exactly undoable after cap rejection")
		await history(true)
		check(await read() == prefix and totals(), "Redo restores only the accepted prefix, never the rejected oversized region")
	print("REDO_MEASUREMENT grid=%d full_bytes=%d tiny_bytes=12288 action_completion_us=%s" % [VoxelCodec.GRID, original.size(), action_times])
	print("Editor Redo GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
