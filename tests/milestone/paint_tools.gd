extends SceneTree
var failures := 0
var checks := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])
func run() -> void:
	root.size = Vector2i(1280, 800)
	var lab = load("res://tests/milestone/paint_tools_lab.gd").new()
	root.add_child(lab)
	await process_frame
	lab.active_transaction = 9
	lab.pending.append(Vector3i(12, 12, 12))
	lab.stroke_element = Elements.Id.SAND
	lab.stroke_radius = 2
	lab.radius = 7
	lab._choose_material(Elements.Id.FIRE)
	check(lab.sim.records.size() == 1 and lab.sim.records[0][2] == 2 and lab.sim.records[0][3] == Elements.Id.SAND,
		"changing to an extended material commits pending stroke with frozen radius and material")
	check(lab.element == Elements.Id.FIRE and not lab.erase and lab.material_buttons[Elements.Id.FIRE].button_pressed,
		"extended material becomes active and selected")
	lab.selection_toggle.button_pressed = true
	check(lab.advanced_tools.visible and lab.selecting, "region shortcut exposes its optional controls")
	lab.advanced_toggle.button_pressed = false
	check(not lab.selecting and not lab.selection_toggle.button_pressed and not lab.selection_mesh.visible,
		"collapsing construction tools leaves painting active, without hidden selection mode")
	lab.erase = true
	lab._choose_material(Elements.Id.OIL)
	check(not lab.erase and lab.sim.records.size() == 1, "choosing another material exits erase without a phantom edit")
	lab.testing = true
	lab.painting = true
	lab.stroke_element = Elements.Id.WATER
	lab.stroke_radius = 1
	for i in 80:
		lab._sample(Vector2(730 + i % 4, 400))
		lab._flush()
	check(lab.pending.is_empty() and lab.pending_surface.is_empty() and lab.sim.records.size() == 1,
		"live pointer samples never dispatch authored or immediate geometry")
	check(not lab.sim.source.is_empty() and lab.sim.source.material == Elements.Id.WATER and lab.sim.source.radius == 1,
		"live source retains frozen stroke metadata")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.position = Vector2(730, 400)
	root.push_input(release, true)
	check(lab.sim.finished == 1 and not lab.painting, "viewport primary release finishes a tick-owned source")
	lab.painting = true
	lab._sample(Vector2(730, 400))
	lab._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(lab.sim.cancelled == 1 and lab.sim.finished == 1, "focus loss cancels instead of adding a pending click")
	# Build strokes accept every motion event; a burst above 64 in one frame is
	# thinned evenly, and the accepted samples still form a face-connected line.
	lab.testing = false
	lab.painting = true
	lab.stroke_target_mode = lab.TargetMode.PLANE
	lab.active_transaction = 11
	lab.previous = Vector3i(-1, -1, -1)
	lab.pending.clear()
	lab.sim.records.clear()
	lab._flush()
	for i in 300:
		lab._sample(Vector2(500 + i, 400))
	var connected: bool = not lab.pending.is_empty()
	for i in range(1, lab.pending.size()):
		var step: Vector3i = (lab.pending[i] as Vector3i - lab.pending[i - 1] as Vector3i).abs()
		connected = connected and step.x + step.y + step.z == 1
	check(lab._frame_samples == 300 and connected, "300 motion events in one frame are thinned yet leave a face-connected pending line (%d cells)" % lab.pending.size())
	var line_cells: int = lab.pending.size()
	lab._flush()
	check(lab.sim.records.size() == 1 and lab.sim.records[0][1].size() == line_cells and lab.pending.is_empty() and lab._frame_samples == 0, "flush records the whole line once and resets the per-frame sample count")
	lab.painting = false
	lab.active_transaction = -1
	lab.queue_free()
	await process_frame
	print("Paint tools: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
