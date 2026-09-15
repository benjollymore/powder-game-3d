extends SceneTree
## read_world over the paired state readback, adopted from the independent
## review: a foreign readback request must never leave a stale layer for the
## next reader, back-to-back readers stay paired, and a simulator without
## the state readback still yields voxels with an empty thermal layer.
var checks := 0
var failures := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	root.size = Vector2i(1280, 800)
	root.get_node("TimeController").set_process_unhandled_input(false)
	# Load at run time: a preload would compile the editor before autoloads exist.
	var lab_script = load("res://tests/milestone/read_world_lab.gd")
	var editor = lab_script.new()
	root.add_child(editor)
	await process_frame
	var got: Array = []
	# 1. A normal read_world pairs its own layers.
	editor.read_world(func(v, t): got.append([v[0], t[0]]))
	await process_frame
	await process_frame
	check(got == [[1, 1]], "own read returns the voxels and temperatures of one job (%s)" % str(got))
	# 2. Something else asks for a state readback while the editor is connected.
	editor.sim.request_state_readback()
	await process_frame
	await process_frame
	check(editor._state_waiters.is_empty(), "a foreign readback completion is dropped, not queued for the next reader")
	# 3. The world heats up, then the editor snapshots it.
	editor.sim.thermal[0] = 200
	got.clear()
	editor.read_world(func(v, t): got.append([v[0], t[0]]))
	await process_frame
	await process_frame
	check(got == [[1, 200]], "read_world after a foreign readback returns the current temperatures (%s)" % str(got))
	check(editor._state_waiters.is_empty(), "no reader is left waiting")
	# 4. Two readers back to back stay paired and ordered.
	got.clear()
	editor.read_world(func(v, t): got.append(["a", t[0]]))
	editor.sim.thermal[0] = 7
	editor.read_world(func(v, t): got.append(["b", t[0]]))
	await process_frame
	await process_frame
	check(got == [["a", 200], ["b", 7]], "back-to-back readers each get their own completion in order (%s)" % str(got))
	# 5. A foreign request interleaved between two readers cannot shift them.
	got.clear()
	editor.read_world(func(v, t): got.append(["a", t[0]]))
	editor.sim.request_state_readback()
	editor.sim.thermal[0] = 9
	editor.read_world(func(v, t): got.append(["b", t[0]]))
	await process_frame
	await process_frame
	check(got.size() == 2 and got[0][0] == "a" and got[1][0] == "b" and editor._state_waiters.is_empty(),
		"an interleaved foreign request completes every reader once and leaves nothing queued (%s)" % str(got))
	# 7. Thermal brushes: Build strokes are undoable thermal records; Test strokes heat at once.
	check(editor.palette.heat_button.visible and editor.palette.cool_button.visible, "thermal brushes show once the simulator has HEAT/COOL modes")
	editor._choose_thermal("heat")
	check(editor.thermal_tool == "heat" and not editor.erase and editor.palette.heat_button.button_pressed, "Heat selects as a tool, not a material")
	editor.active_transaction = 5
	editor.stroke_thermal = "heat"
	editor.stroke_radius = 2
	editor.pending.append(Vector3i(12, 12, 12))
	editor._flush()
	check(editor.sim.thermal_strokes == [[5, [Vector3i(12, 12, 12)], 2, editor.thermal_strength]] and editor.pending.is_empty(),
		"a Build heat stroke records one undoable thermal stroke of +%d K" % int(editor.thermal_strength))
	editor.stroke_thermal = "cool"
	editor.pending_surface.append({"origin": Vector3.ZERO, "direction": Vector3.FORWARD})
	editor._flush()
	check(editor.sim.thermal_strokes.size() == 1 and editor.sim.surface_thermal == [[5, 1, 2, -editor.thermal_strength]] and editor.pending_surface.is_empty(),
		"a surface-targeted thermal stroke records one undoable surface thermal stroke")
	# Stroke speed must not change the heat deposited: a slow drag (one cell per
	# flush) and a fast drag (the whole path in one flush) stamp the same centres.
	editor.sim.thermal_strokes.clear()
	editor.stroke_thermal = "heat"
	editor.stroke_radius = 3
	editor._end_stroke()
	editor.active_transaction = 6
	var path: Array[Vector3i] = []
	for x in range(20, 31):
		path.append(Vector3i(x, 40, 40))
	for cell in path:
		editor.pending.append(cell)
		editor._flush()
	var slow: Array = []
	for record in editor.sim.thermal_strokes:
		slow.append_array(record[1])
	editor.sim.thermal_strokes.clear()
	editor._end_stroke()
	editor.active_transaction = 7
	editor.pending.append_array(path)
	editor._flush()
	var fast: Array = []
	for record in editor.sim.thermal_strokes:
		fast.append_array(record[1])
	check(slow == fast and slow == [Vector3i(20, 40, 40), Vector3i(23, 40, 40), Vector3i(26, 40, 40), Vector3i(29, 40, 40)],
		"slow and fast heat strokes stamp the same radius-spaced centres (%s vs %s)" % [str(slow), str(fast)])
	editor._end_stroke()
	editor.active_transaction = -1
	editor.testing = true
	editor.painting = true
	editor.stroke_thermal = "cool"
	editor.stroke_radius = 2
	editor._sample(Vector2(730, 400))
	editor._sample(Vector2(731, 400))
	check(editor.sim.live_thermal.size() == 1 and editor.sim.live_thermal[0][2] == -editor.thermal_strength and editor.sim.live_thermal[0][1] == 2,
		"live cooling paints immediately at the pointer once per spacing (%s)" % str(editor.sim.live_thermal))
	editor.stroke_target_mode = editor.TargetMode.SURFACE
	editor.stroke_view = {"section": false, "axis": 2, "depth": 64}
	editor.surface_connect = false
	editor._sample(Vector2(732, 400))
	editor._sample(Vector2(733, 400))
	check(editor.sim.live_surface_thermal.size() == 2 and editor.sim.live_surface_thermal[0][0][0].connect == false and editor.sim.live_surface_thermal[1][0][0].connect == true,
		"live surface cooling sends each sample as a ray, the first starting a new segment (%d)" % editor.sim.live_surface_thermal.size())
	editor.stroke_target_mode = editor.TargetMode.PLANE
	editor.painting = false
	editor.testing = false
	editor._choose_material(Elements.Id.SAND)
	check(editor.thermal_tool.is_empty(), "choosing a material clears the thermal tool")
	# 6. Without a state readback API the voxel path still works.
	editor.sim.queue_free()
	editor.sim = lab_script.PlainStub.new()
	editor.add_child(editor.sim)
	got.clear()
	editor.read_world(func(v, t): got.append([v[0], t.size()]))
	await process_frame
	await process_frame
	check(got == [[1, 0]], "a simulator without request_state_readback yields voxels and an empty thermal layer (%s)" % str(got))
	editor.queue_free()
	await process_frame
	print("Read world FIFO: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
