extends SceneTree
## Injected Godot events, not physical trackpad validation. Bounded visible run.
var lab: Node3D
var checks := 0
var failures := 0
var point := Vector2(900, 400)

func _initialize() -> void:
	create_timer(45.0).timeout.connect(func():
		push_error("Trackpad test timed out")
		quit(1))
	lab = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(lab)
	_run()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func send(event: InputEvent) -> void:
	root.push_input(event, true)

func pan(delta: Vector2, shift := false, position := Vector2(900, 400)) -> void:
	var event := InputEventPanGesture.new()
	event.delta = delta
	event.shift_pressed = shift
	event.position = position
	send(event)

func pinch(factor: float, position := Vector2(900, 400)) -> void:
	var event := InputEventMagnifyGesture.new()
	event.factor = factor
	event.position = position
	send(event)

func button(id: int, pressed: bool, alt := false, shift := false, factor := 1.0, position := Vector2(900, 400)) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = id
	event.pressed = pressed
	event.alt_pressed = alt
	event.shift_pressed = shift
	event.factor = factor
	event.position = position
	send(event)
	if pressed and id in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		# macOS emits paired wheel press/release. Omitting release leaves
		# Viewport GUI mouse focus captured by the numeric control in this test.
		var release := event.duplicate()
		release.pressed = false
		send(release)

func motion(delta: Vector2, position := Vector2(900, 400)) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.relative = delta
	send(event)

func read() -> PackedByteArray:
	await process_frame
	lab.sim.request_readback(func(_bytes): pass)
	return await lab.sim.readback_ready

func _run() -> void:
	for i in 8:
		await process_frame
	var original := await read()
	var initial_yaw: float = lab.yaw
	pan(Vector2(3, 2))
	check(lab.yaw != initial_yaw and lab.pitch != 0.0, "two-finger swipe orbits via viewport event routing")
	check(not lab.painting and not lab.capturing and lab.undo_history.is_empty(), "native navigation creates no paint transaction")
	initial_yaw = lab.yaw
	pan(Vector2(3, 2), true)
	check(lab.camera_target != Vector3.ZERO and lab.yaw == initial_yaw, "Shift swipe pans without orbiting")
	var initial_distance: float = lab.distance
	pinch(1.2)
	check(is_equal_approx(lab.distance, initial_distance / 1.2), "pinch-out zooms in by native magnification factor")
	initial_distance = lab.distance
	pinch(1.0)
	pinch(0.0)
	pinch(-1.0)
	check(lab.distance == initial_distance, "neutral and invalid pinch factors do not move camera")
	pinch(10000.0)
	check(lab.distance == 0.7, "pinch zoom clamps near distance")
	pinch(0.00001)
	check(lab.distance == 4.0, "pinch zoom clamps far distance")
	pan(Vector2(100000, 100000), true)
	check(lab.camera_target.abs().max_axis_index() >= 0 and lab.camera_target.abs().length() <= sqrt(3.0) * 1.501, "pan target remains bounded")
	lab._face_plane()
	check(lab.camera_target == Vector3.ZERO and lab.distance == 1.25, "center recovers a panned and zoomed world")
	button(MOUSE_BUTTON_LEFT, true, true)
	check(lab.navigation_button == MOUSE_BUTTON_LEFT and not lab.painting and not lab.capturing, "Option-primary drag starts navigation without painting")
	initial_yaw = lab.yaw
	motion(Vector2(30, 10))
	check(lab.yaw != initial_yaw, "Option-primary drag moves camera")
	button(MOUSE_BUTTON_LEFT, false, false, false, 1.0, Vector2(40, 40))
	check(lab.navigation_button == MOUSE_BUTTON_NONE and not lab.orbiting, "primary release over toolbar terminates navigation")
	button(MOUSE_BUTTON_LEFT, true, true, true)
	initial_yaw = lab.yaw
	motion(Vector2(20, 10)) # Shift/Option flags no longer present: captured mode wins.
	check(lab.camera_target != Vector3.ZERO and lab.yaw == initial_yaw, "Option-Shift-primary pans and keeps its mode until release")
	lab._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	check(lab.navigation_button == MOUSE_BUTTON_NONE and not lab.painting, "focus loss releases navigation and painting")
	button(MOUSE_BUTTON_LEFT, false) # balance injected button in Viewport too
	button(MOUSE_BUTTON_RIGHT, true)
	initial_yaw = lab.yaw
	motion(Vector2(15, 0))
	check(lab.yaw != initial_yaw, "physical right-button orbit still works")
	button(MOUSE_BUTTON_RIGHT, false)
	lab._face_plane()
	initial_distance = lab.distance
	button(MOUSE_BUTTON_WHEEL_UP, true, false, false, 0.1)
	check(is_equal_approx(lab.distance, initial_distance * pow(0.9, 0.1)), "high-resolution wheel zoom honors fractional factor")
	var initial_depth: int = lab.depth
	button(MOUSE_BUTTON_WHEEL_UP, true, false, true, 0.25)
	check(lab.depth == initial_depth, "fractional plane scroll does not round prematurely")
	for i in 3:
		button(MOUSE_BUTTON_WHEEL_UP, true, false, true, 0.25)
	check(lab.depth == initial_depth + 1, "four quarter wheel units move exactly one plane cell")
	lab.depth_input.value = VoxelCodec.GRID - 1
	button(MOUSE_BUTTON_WHEEL_UP, true, false, true, 10.0)
	button(MOUSE_BUTTON_WHEEL_DOWN, true, false, true, 1.0)
	check(lab.depth == VoxelCodec.GRID - 2, "depth boundary accumulates no hidden overscroll debt")
	# Gesture events can pass through GUI to _unhandled_input; guard by position,
	# not by the previously hovered control. This is an actual Viewport route.
	var saved_transform: Transform3D = lab.camera.transform
	initial_depth = lab.depth
	var initial_radius: int = lab.radius
	pan(Vector2(5, 5), false, Vector2(40, 40))
	pinch(1.3, Vector2(40, 40))
	check(lab.camera.transform == saved_transform, "pan and pinch over toolbar never navigate camera")
	check(lab.depth == initial_depth and lab.radius == initial_radius, "toolbar gestures do not change plane or brush radius")
	var radius_position: Vector2 = lab.radius_input.get_global_rect().get_center()
	motion(Vector2.ZERO, radius_position)
	button(MOUSE_BUTTON_WHEEL_UP, true, false, false, 1.0, radius_position)
	check(lab.camera.transform == saved_transform and lab.depth == initial_depth, "wheel over brush field cannot leak into camera or depth")
	check(lab.tools_panel.get_global_rect().end.y <= root.get_visible_rect().size.y, "toolbar remains inside laptop viewport with scrollable content")
	check(await read() == original, "all navigation and toolbar event probes leave GPU material bytes untouched")
	# A native gesture arriving mid-paint must stop it, and ordinary primary drag
	# must still start the existing paint transaction after navigation completes.
	lab._face_plane()
	lab.depth_input.value = VoxelCodec.GRID / 2
	var cell := Vector3i(VoxelCodec.GRID / 2, VoxelCodec.GRID * 3 / 4, VoxelCodec.GRID / 2)
	var world: Vector3 = lab.sim.global_transform * ((Vector3(cell) + Vector3.ONE * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5)
	var paint_position: Vector2 = lab.camera.unproject_position(world)
	motion(Vector2.ZERO, paint_position)
	button(MOUSE_BUTTON_LEFT, true, false, false, 1.0, paint_position)
	check(lab.painting and lab.capturing, "ordinary primary press still begins authored painting")
	pan(Vector2(1, 0))
	check(not lab.painting, "native swipe ends an active paint stroke")
	button(MOUSE_BUTTON_LEFT, false)
	while lab.capturing:
		await process_frame
	check(await read() != original, "ordinary paint transaction still writes GPU material")
	print("Trackpad input: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
