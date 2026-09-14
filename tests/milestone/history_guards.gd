extends SceneTree
const Budget := preload("res://scripts/editor/history_budget.gd")
class FailedCaptureSim extends Node3D:
	var edit_epoch := 0
	func reverse_edit_transaction(_original, callback) -> bool:
		callback.call_deferred({"epoch": 0, "applied": false, "valid": false, "error": "Injected regional readback failure"})
		return true
var checks := 0
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1
func record(lo := Vector3i.ZERO, value := 0) -> Dictionary:
	var bytes := PackedByteArray()
	bytes.resize(2048)
	bytes.fill(value)
	return {"valid": true, "epoch": 0, "id": 1, "bytes": 2048, "error": "",
		"regions": [{"lo": lo, "hi": lo + Vector3i.ONE * 8, "bytes": bytes}]}
func run() -> void:
	var undo: Array = [{"bytes": 4, "id": "oldest"}, {"bytes": 4, "id": "nearest past"}]
	var redo: Array = [{"bytes": 4, "id": "farthest future"}, {"bytes": 4, "id": "nearest future"}]
	var sizes := Budget.trim(undo, redo, 8, 8, 12)
	check(sizes == Vector2i(4, 8) and undo[0].id == "nearest past" and redo.size() == 2,
		"shared cap counts both stacks and evicts oldest past while preserving the contiguous future")
	sizes = Budget.trim(undo, redo, sizes.x, sizes.y, 4)
	check(sizes == Vector2i(0, 4) and undo.is_empty() and redo[0].id == "nearest future",
		"when past is exhausted cap removes farthest future, preserving next Redo")
	sizes = Budget.trim(undo, redo, sizes.x, sizes.y, 4)
	check(sizes == Vector2i(0, 4) and redo.size() == 1, "exact cap boundary does not discard history")
	check(Budget.trim([], [], 0, 0) == Vector2i.ZERO, "empty history remains empty")
	# No scene insertion or RenderingDevice: exercise production reply validation
	# before the branch that could enqueue restoration.
	var sim = load("res://scripts/sim/voxel_sim.gd").new()
	var original := record()
	check(sim._history_record_valid(original), "aligned exact regional history is accepted")
	var bad := original.duplicate(true)
	bad.regions.append(bad.regions[0].duplicate(true))
	bad.bytes *= 2
	check(not sim._history_record_valid(bad), "duplicate inverse tiles are rejected before GPU submission")
	bad = record(Vector3i.ONE)
	check(not sim._history_record_valid(bad), "unaligned history bounds are rejected")
	bad = original.duplicate(true)
	bad.regions[0].bytes.resize(2047)
	check(not sim._history_record_valid(bad), "truncated packed regional bytes are rejected")
	var replies: Array = []
	var callback := func(reply): replies.append(reply)
	for kind in ["truncated", "wrong region", "readback error", "stale revision", "stale tick", "stale epoch"]:
		var captured := record(Vector3i.ZERO, 2)
		var revision: int = sim.edit_revision
		var at_tick: int = sim.tick
		match kind:
			"truncated": captured.regions[0].bytes.resize(2047)
			"wrong region": captured = record(Vector3i(8, 0, 0), 2)
			"readback error": captured.error = "Injected readback failure"
			"stale revision": revision -= 1
			"stale tick": at_tick -= 1
			"stale epoch": captured.epoch = -1
		sim._complete_history_capture(captured, original, revision, at_tick, true, callback)
		var reply: Dictionary = replies.pop_back()
		check(not reply.applied and not reply.valid and sim.edit_revision == 0,
			"%s inverse fails before any restoration submission" % kind)
	var same := record()
	sim._complete_history_capture(same, original, 0, sim.tick, false, callback)
	check(replies.back().valid and not replies.back().changed and not replies.back().applied,
		"read-only branch inspection detects an exact no-op without mutating material")
	var changed := record(Vector3i.ZERO, 2)
	sim._complete_history_capture(changed, original, 0, sim.tick, false, callback)
	check(replies.back().valid and replies.back().changed and not replies.back().applied,
		"packed-byte branch inspection detects a real authored change")
	sim.free()
	var editor = load("res://tests/milestone/paint_tools_lab.gd").new()
	root.add_child(editor)
	editor.sim.free()
	editor.sim = FailedCaptureSim.new()
	editor.add_child(editor.sim)
	editor.undo_history.append(original)
	editor.undo_bytes = original.bytes
	editor.undo_edit()
	check(editor.capturing and editor.undo_history.size() == 1, "source Undo remains retained while inverse capture is pending")
	editor.pending_authored = load("res://scripts/editor/pending_gesture.gd").new({"epoch": 0})
	editor.pending_authored.add_cell(Vector3i.ONE)
	await process_frame
	check(not editor.capturing and editor.undo_history.size() == 1 and editor.undo_history[0] == original and editor.redo_history.is_empty(),
		"failed inverse capture leaves the only recoverable Undo entry and its exact bytes intact")
	check(editor.pending_authored == null, "failed inverse capture cancels waiting paint instead of replaying it after a failed action")
	editor.queue_free()
	await process_frame
	print("History guards: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
