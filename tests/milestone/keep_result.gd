extends SceneTree
## Keep-result bookkeeping over a stub simulator that mirrors the history
## contract: capture returns aligned tile records, restore writes them back,
## upload starts a new epoch. Tile diffing is checked exactly.
const KeepResult := preload("res://scripts/editor/keep_result.gd")
const EditGPU := preload("res://scripts/sim/voxel_edit_gpu.gd")
var checks := 0
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])
func world(cells: Dictionary) -> PackedByteArray:
	var data := WorldBuilder.empty()
	for cell in cells:
		data[VoxelCodec.index(cell.x, cell.y, cell.z)] = VoxelCodec.encode(cells[cell], 7, 0)
	return data.to_byte_array()
func run() -> void:
	root.size = Vector2i(1280, 800)
	var n := VoxelCodec.GRID
	var tile: int = EditGPU.TILE
	var a := world({Vector3i(3, 3, 3): Elements.Id.WALL})
	var b := world({Vector3i(3, 3, 3): Elements.Id.WALL, Vector3i(20, 9, 9): Elements.Id.SAND, Vector3i(n - 1, n - 1, n - 1): Elements.Id.WATER})
	var tiles := KeepResult.changed_tiles(a, b, n, tile)
	check(tiles == [Vector3i(2, 1, 1), Vector3i(n / tile - 1, n / tile - 1, n / tile - 1)], "diff reports exactly the tiles whose cells differ, sorted")
	check(KeepResult.changed_tiles(a, a, n, tile).is_empty() and KeepResult.changed_tiles(a, b.slice(0, 16), n, tile).is_empty(),
		"identical or malformed worlds report no tiles")
	var bounds := KeepResult.bounds(tiles, n, tile)
	check(bounds[0].lo == Vector3i(16, 8, 8) and bounds[0].hi == Vector3i(24, 16, 16) and bounds[1].hi == Vector3i(n, n, n),
		"bounds are aligned history tiles clamped to the grid")
	check(KeepResult.byte_count(tiles, n, tile) == 2 * tile * tile * tile * 4, "byte accounting matches the tile volume")
	var lab = load("res://tests/milestone/keep_result_lab.gd").new()
	root.add_child(lab)
	await process_frame
	lab.sim.world = b
	lab.build_snapshot = a
	lab.testing = true
	lab.play_button.text = "Return"
	lab.document.reset()
	root.get_node("TimeController").paused = false
	lab.keep_result()
	check(lab.keeping and lab.capturing and root.get_node("TimeController").paused, "keeping pauses the experiment and blocks other edits")
	for i in 6:
		await process_frame
	check(not lab.keeping and not lab.testing and lab.play_button.text.begins_with("Run"), "keep leaves Test and returns to Build")
	check(lab.sim.world == b and lab.sim.uploads == [a] and lab.sim.restored.size() == 1, "the authored world was restored, then the live tiles written on top")
	check(lab.undo_history.size() == 1 and lab.undo_history[0].epoch == lab.sim.edit_epoch and lab.undo_history[0].regions.size() == 2 and lab.undo_bytes == lab.undo_history[0].bytes,
		"one undo record holds the authored tiles at the new epoch")
	check(lab.document.is_dirty() and lab.edit_message.begins_with("Kept"), "the kept build is unsaved and reported")
	var before: PackedByteArray = lab.undo_history[0].regions[0].bytes
	check(before.size() == tile * tile * tile * 4 and before == lab.sim.tile_bytes(a, bounds[0]), "the undo record carries the authored before-image, not the live tiles")
	lab.testing = true
	lab.sim.world = b
	lab.build_snapshot = b
	lab.keep_result()
	for i in 4:
		await process_frame
	check(not lab.keeping and lab.testing and lab.edit_message.begins_with("Nothing changed") and lab.undo_history.size() == 1,
		"an unchanged experiment keeps nothing and stays in Test")
	lab.testing = true
	lab.capturing = true
	lab.keep_result()
	check(lab._queued_editor_action == "keep" and not lab.keeping, "keep requested during capture waits like other actions")
	lab.capturing = false
	lab.testing = false
	await process_frame
	await process_frame
	check(not lab.keeping and lab.undo_history.size() == 1, "a queued keep is dropped when Test already ended")
	lab.queue_free()
	await process_frame
	print("Keep result CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
