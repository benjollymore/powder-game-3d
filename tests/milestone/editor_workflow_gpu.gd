extends SceneTree
## Parsed engine button/key/gesture events plus synchronized OS cursor position.
## This is not a physical trackpad test.
## The production editor, TimeController and Input singleton remain active.
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
var editor: Node3D
var sim: Node3D
var clock: Node
var checks := 0
var failures := 0
var pointer := Vector2.ZERO
var held := false
var output_dir := "/tmp/editor-workflow"
var original_accumulation := true
var original_cursor := Vector2i.ZERO
var input_configured := false
func _initialize() -> void:
	create_timer(100.0).timeout.connect(func():
		push_error("Editor workflow watchdog expired")
		_restore_input()
		quit(1))
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1
func frames(count: int = 2) -> void:
	for i in count:
		await process_frame
func move_to(position: Vector2, alt := false, shift := false) -> void:
	# On macOS the per-frame viewport poll reads the real cursor, even after a
	# parsed motion event. Synchronize that position; clicks remain synthetic.
	Input.warp_mouse(position)
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = position - pointer
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	event.alt_pressed = alt
	event.shift_pressed = shift
	pointer = position
	Input.parse_input_event(event)
func mouse(down: bool, alt := false, shift := false) -> void:
	held = down
	var event := InputEventMouseButton.new()
	event.position = pointer
	event.global_position = pointer
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	event.alt_pressed = alt
	event.shift_pressed = shift
	event.pressed = down
	Input.parse_input_event(event)
func key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.unicode = code + 32 if code >= KEY_A and code <= KEY_Z else code if code < 128 else 0
	event.pressed = true
	Input.parse_input_event(event)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
func find_button(prefix: String, node: Node = editor.tools_column) -> BaseButton:
	if node is BaseButton and node.text.begins_with(prefix):
		return node
	for child in node.get_children():
		var found := find_button(prefix, child)
		if found != null:
			return found
	return null
func click(control: Control) -> void:
	if control == null or not control.is_visible_in_tree():
		push_error("Workflow requested a missing or hidden UI control")
		_restore_input()
		quit(1)
		return
	var center := control.get_global_rect().get_center()
	move_to(center)
	await frames(1)
	mouse(true)
	await frames(1)
	mouse(false)
	await frames(2)
func settled() -> void:
	while editor.capturing or not editor._queued_editor_action.is_empty():
		await process_frame
	await frames(2)
func read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready
func point(cell: Vector3i) -> Vector2:
	return editor.camera.unproject_position(sim.to_global((Vector3(cell) + Vector3.ONE * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5))
func id_at(bytes: PackedByteArray, cell: Vector3i) -> int:
	return bytes[VoxelCodec.index(cell.x, cell.y, cell.z) * 4]
func preserved_walls(before: PackedByteArray, after: PackedByteArray) -> bool:
	for i in range(0, before.size(), 4):
		if before[i] == Elements.Id.WALL and after[i] != Elements.Id.WALL:
			return false
	return true
func stroke(first: Vector3i, last: Vector3i, inspect_hold := false) -> void:
	move_to(point(first))
	await frames(1)
	mouse(true)
	await frames(4)
	if inspect_hold:
		check(Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and editor.painting and editor.is_processing(),
			"parsed primary hold survives four active editor frames")
	move_to(point(last)) # One fast motion event must still form a connected stroke.
	await frames(3)
	mouse(false)
	await settled()
func capture(name: String) -> void:
	move_to(Vector2(1100, 750))
	await frames(3)
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output_dir.path_join(name + ".png"))
func _restore_input() -> void:
	if not input_configured:
		return
	if held:
		mouse(false)
	Input.use_accumulated_input = original_accumulation
	# DisplayServer accepts coordinates relative to the focused window.
	DisplayServer.warp_mouse(original_cursor - DisplayServer.window_get_position(root.get_window_id()))
	input_configured = false


func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="):
			output_dir = arg.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(output_dir)
	original_cursor = DisplayServer.mouse_get_position()
	original_accumulation = Input.use_accumulated_input
	input_configured = true
	Input.use_accumulated_input = false # Deterministic delivery, ordinary frame loop.
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	clock = root.get_node("TimeController")
	await frames(12)
	check(editor.is_processing() and clock.is_processing(), "production editor and time loops remain enabled")
	var original := await read()
	var n := VoxelCodec.GRID
	var first := Vector3i(n * 3 / 8, n * 9 / 16, n / 2)
	var last := Vector3i(n * 5 / 8, n * 7 / 16, n / 2)
	await click(editor.material_buttons[Elements.Id.WALL])
	key(KEY_BRACKETLEFT)
	await frames()
	check(editor.element == Elements.Id.WALL and editor.radius == 2, "GUI material click and bracket shortcut select a radius-two wall brush")
	await stroke(first, last, true)
	var ramp := await read()
	var connected := true
	for cell in Geometry.stroke(first, last):
		connected = connected and id_at(ramp, cell) == Elements.Id.WALL
	check(connected and preserved_walls(original, ramp), "fast parsed drag paints a connected ramp while preserving container walls")
	check(not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not editor.painting and editor.undo_history.size() == 1,
		"parsed release ends Input hold and completes one authored history entry")
	var undo_button := find_button("Undo build")
	var undo_activations := [0]
	undo_button.pressed.connect(func(): undo_activations[0] += 1)
	await click(undo_button)
	await settled()
	check(await read() == original and editor.undo_history.is_empty(), "GUI Undo restores exact original packed bytes")
	key(KEY_SPACE) # Undo retains actual GUI focus from the preceding mouse click.
	await settled()
	check(editor.testing and undo_activations[0] == 1, "parsed Space runs Test without also activating the focused Undo button")
	await click(editor.play_button)
	await settled()
	check(not editor.testing and await read() == original, "GUI Return after keyboard Run restores the untouched construction")
	await stroke(first, last)
	ramp = await read()
	await click(editor.material_buttons[Elements.Id.SAND])
	key(KEY_BRACKETRIGHT)
	await frames()
	await stroke(Vector3i(n * 7 / 16, n * 11 / 16, n / 2), Vector3i(n * 9 / 16, n * 11 / 16, n / 2))
	var authored := await read()
	check(sim.histogram(authored)[Elements.Id.SAND] > 0 and editor.undo_history.size() == 2 and preserved_walls(ramp, authored),
		"second GUI-selected material produces sand above the ramp without replacing walls")
	# Option-primary drag uses Input's actual held state between process frames.
	var yaw_before: float = editor.yaw
	move_to(Vector2(950, 400))
	mouse(true, true)
	await frames(3)
	move_to(Vector2(1020, 420), true)
	await frames(3)
	mouse(false, true)
	await frames(2)
	check(editor.yaw != yaw_before and not editor.painting and not editor.orbiting, "parsed Option-primary drag orbits and releases cleanly")
	var pan := InputEventPanGesture.new()
	pan.position = Vector2(1000, 400)
	pan.delta = Vector2(1.0, 0.5)
	pan.shift_pressed = true
	Input.parse_input_event(pan)
	var pinch := InputEventMagnifyGesture.new()
	pinch.position = pan.position
	pinch.factor = 1.1
	Input.parse_input_event(pinch)
	await frames(2)
	check(editor.camera_target != Vector3.ZERO and editor.distance < 1.25, "parsed pan and pinch reach camera controls")
	await click(find_button("Center"))
	check(await read() == authored and editor.undo_history.size() == 2 and editor.camera_target == Vector3.ZERO,
		"navigation and GUI Center leave exact authored matter and history unchanged")
	await capture("authored-ramp")
	# Export a reusable fixture from the verified authored bytes. This is an
	# artifact operation, explicitly not coverage of the native Save dialog.
	var archive := preload("res://scripts/editor/archive_job.gd").new()
	var save_error: Error = archive.save_authored(output_dir.path_join("painted-ramp.p3d"), authored, n)
	if save_error == OK:
		while not archive.is_ready():
			await process_frame
		check(archive.take_result().ok, "verified authored construction is exported as a reusable .p3d fixture")
	else:
		check(false, "could not start fixture export")
	await click(editor.play_button)
	await settled()
	check(editor.testing and editor.build_snapshot == authored and not clock.paused, "GUI Run captures the completed construction and starts Test")
	await frames(12)
	await click(editor.pause_button)
	var paused := await read()
	var paused_tick: int = sim.tick
	await frames(8)
	check(clock.paused and sim.tick == paused_tick and await read() == paused, "GUI Pause preserves GPU state with both frame loops active")
	await click(editor.step_button)
	await read()
	check(clock.paused and sim.tick == paused_tick + 1, "GUI Single step advances exactly one tick through the active time loop")
	# A paused click is queued, then consumed by the next GUI step.
	await click(editor.material_buttons[Elements.Id.SAND])
	for i in 3:
		key(KEY_BRACKETLEFT)
	await frames(2)
	var before_click := await read()
	move_to(point(Vector3i(n * 9 / 16, n * 3 / 4, n / 2)))
	mouse(true)
	await frames(3)
	mouse(false)
	await frames(2)
	check(await read() == before_click and not editor.painting, "paused parsed press/hold/release makes no unscheduled material mutation")
	await click(editor.step_button)
	var stepped := await read()
	check(sim.histogram(stepped)[Elements.Id.SAND] == sim.histogram(before_click)[Elements.Id.SAND] + 1,
		"GUI step consumes the completed paused click exactly once")
	await click(editor.pause_button) # Resume.
	move_to(point(Vector3i(n * 9 / 16, n * 3 / 4, n / 2)))
	mouse(true)
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 350:
		await process_frame
	check(Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and editor.painting, "live held source survives the production per-frame Input guard")
	move_to(point(Vector3i(n * 10 / 16, n * 3 / 4, n / 2)))
	await frames(3)
	mouse(false)
	await click(editor.pause_button)
	var live := await read()
	check(sim.histogram(live)[Elements.Id.SAND] > sim.histogram(stepped)[Elements.Id.SAND] + 1,
		"active-frame held source adds multiple real grains while simulation runs")
	check(editor.build_snapshot == authored and editor.undo_history.size() == 2, "live painting leaves authored snapshot/history separate")
	print("WORKFLOW_MATERIAL sand_before_click=", sim.histogram(before_click)[Elements.Id.SAND], " sand_after_step=", sim.histogram(stepped)[Elements.Id.SAND], " sand_after_live_hold=", sim.histogram(live)[Elements.Id.SAND])
	await capture("paused-experiment")
	await click(editor.play_button)
	await settled()
	check(not editor.testing and clock.paused and await read() == authored, "GUI Return restores exact authored construction after live input")
	await capture("restored-build")
	await click(find_button("Undo build"))
	await settled()
	check(await read() == ramp and editor.undo_history.size() == 1, "GUI Undo after Return removes only the last authored sand stroke")
	_restore_input()
	await frames(2)
	check(DisplayServer.mouse_get_position().distance_to(original_cursor) <= 2.0, "workflow restores the original OS cursor position")
	print("Editor workflow GPU: %d checks, %d failures; evidence=%s" % [checks, failures, output_dir])
	quit(1 if failures else 0)
