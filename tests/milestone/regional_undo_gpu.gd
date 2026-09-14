extends SceneTree
var sim: Node3D
var checks := 0
var failures := 0
func _initialize() -> void:
	create_timer(60.0).timeout.connect(func():
		push_error("Regional undo GPU watchdog expired")
		quit(1))
	root.get_node("TimeController").paused = true
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	root.add_child(sim)
	_run()
func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1
func read() -> PackedByteArray:
	await process_frame
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready
func one(cell: Vector3i) -> Array[Vector3i]:
	return [cell]
func begin() -> int:
	return sim.begin_edit_transaction(func(_result): pass)
func finish(id: int) -> Dictionary:
	sim.finish_edit_transaction(id)
	return await sim.edit_transaction_ready
func _run() -> void:
	for i in 8:
		await process_frame
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(32, 32, 32), Vector3i(33, 40, 40), Elements.Id.WALL)
	sim.upload(data.to_byte_array())
	var before := await read()
	var id := begin()
	var points: Array[Vector3i] = [Vector3i(31, 34, 34), Vector3i(32, 34, 34), Vector3i(33, 34, 34)]
	sim.record_stroke(id, points, 0, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 42)
	sim.record_stroke(id, one(Vector3i(33, 34, 34)), 0, Elements.Id.AIR, sim.BrushMode.ERASE, 43)
	var result := await finish(id)
	check(result.error == "", "regional before-images complete without error")
	check(result.bytes == 4096, "two first-touched 8³ tiles transfer 4096 bytes, independent of grid size")
	var after := await read()
	check(after[VoxelCodec.index(32, 34, 34) * 4] == Elements.Id.WALL, "recorded additive brush preserves wall")
	check(after[VoxelCodec.index(31, 34, 34) * 4] == Elements.Id.SAND, "recorded stroke mutates intended cell")
	check(after[VoxelCodec.index(33, 34, 34) * 4] == Elements.Id.AIR, "later erase executes in transaction order")
	check(sim.restore_edit_transaction(result), "regional undo accepts same-world transaction")
	check(await read() == before, "overlapping brush commands undo all packed bytes exactly")
	id = begin()
	sim.record_region(id, Vector3i(30, 33, 33), Vector3i(36, 36, 36), Elements.Id.WATER)
	sim.record_stroke(id, one(Vector3i(31, 34, 34)), 1, Elements.Id.AIR, sim.BrushMode.ERASE)
	result = await finish(id)
	check(result.bytes == 4096, "mixed region and brush commands retain one before-image per tile")
	sim.restore_edit_transaction(result)
	check(await read() == before, "mixed region/brush undo restores exact original state")
	id = begin()
	sim.record_region(id, Vector3i(-10, -10, -10), Vector3i(3, 3, 3), Elements.Id.WATER)
	result = await finish(id)
	check(result.bytes == 2048, "clamped edge region captures only one in-bounds tile")
	sim.restore_edit_transaction(result)
	check(await read() == before, "edge-region undo restores exact original state")
	sim.clear()
	check(not sim.restore_edit_transaction(result), "world reset epoch rejects stale undo")
	id = begin()
	sim.upload(before)
	sim.record_stroke(id, points, 1, Elements.Id.SAND)
	sim.record_region(id, Vector3i(1, 1, 1), Vector3i(8, 8, 8), Elements.Id.WATER)
	await finish(id)
	check(await read() == before, "old transaction cannot mutate a new world after reset")
	if VoxelCodec.GRID >= 256:
		id = begin()
		sim.record_stroke(id, one(Vector3i(31, 34, 34)), 0, Elements.Id.SAND)
		var prefix := await read()
		sim.record_region(id, Vector3i.ZERO, Vector3i.ONE * VoxelCodec.GRID, Elements.Id.WATER)
		result = await finish(id)
		check(result.error != "" and result.valid, "oversized transaction reports limit while retaining valid prefix undo")
		check(await read() == prefix, "oversized remaining region causes no partial mutation")
		check(result.bytes == 2048, "rejected region transfers no additional undo tiles")
		sim.restore_edit_transaction(result)
		check(await read() == before, "accepted prefix remains exactly undoable after cap rejection")
	print("Regional undo GPU: %d checks, %d failures; full volume=%d bytes, tiny stroke=4096 bytes" % [checks, failures, before.size()])
	quit(1 if failures else 0)
