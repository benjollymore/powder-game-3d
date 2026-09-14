extends SceneTree
## Actual Viewport/GUI routing with the production editor input methods.
## A minimal simulation stub keeps this regression headless; no physics claims.
var lab: Node3D
var checks := 0
var failures := 0

func _initialize() -> void:
	create_timer(10.0).timeout.connect(func(): quit(1))
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func pinch(position: Vector2, factor := 1.05) -> void:
	var event := InputEventMagnifyGesture.new()
	event.position = position
	event.factor = factor
	root.push_input(event, true)

func pan(position: Vector2) -> void:
	var event := InputEventPanGesture.new()
	event.position = position
	event.delta = Vector2(1, 0.5)
	event.shift_pressed = true
	root.push_input(event, true)

func run() -> void:
	root.size = Vector2i(1280, 800)
	lab = load("res://tests/discovery/gesture_input_lab.gd").new()
	root.add_child(lab)
	await process_frame
	var scene_point := Vector2(1000, 400)
	var tools_point := Vector2(40, 40)
	var distance: float = lab.distance
	pinch(scene_point)
	check(lab.distance < distance, "scene pinch starts zooming")
	distance = lab.distance
	pinch(tools_point)
	check(lab.distance < distance, "pinch continues across toolbar instead of cutting out")
	lab._reset_gesture()
	pan(scene_point)
	var target: Vector3 = lab.camera_target
	pan(tools_point)
	check(lab.camera_target != target, "Shift-pan continues across toolbar instead of cutting out")
	check(not lab.painting and not lab.capturing and lab.pending.is_empty(), "gesture stream creates no paint transaction")
	# A GUI consumer overlapping the scene can swallow _unhandled_input events.
	# Scene navigation must run before that phase, without relying on hover state.
	var overlay := Control.new()
	overlay.position = Vector2(800, 200)
	overlay.size = Vector2(400, 500)
	overlay.gui_input.connect(func(_event): overlay.accept_event())
	root.add_child(overlay)
	lab._reset_gesture()
	distance = lab.distance
	pinch(scene_point)
	check(lab.distance < distance, "scene pinch survives a GUI event consumer")
	target = lab.camera_target
	pan(scene_point)
	check(lab.camera_target != target, "scene pan survives a GUI event consumer")
	overlay.queue_free()
	await process_frame
	lab._reset_gesture()
	distance = lab.distance
	target = lab.camera_target
	pinch(tools_point)
	pan(scene_point)
	check(lab.distance == distance and lab.camera_target == target, "toolbar-origin sequence cannot turn into camera navigation")
	var idle_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - idle_start < 400:
		await process_frame
	pan(scene_point)
	check(lab.camera_target != target, "new gesture after idle can acquire the scene")
	lab._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	distance = lab.distance
	pinch(tools_point)
	check(lab.distance == distance, "focus loss clears previous scene ownership")
	# Trace path and tiny native deltas also go through production dispatch.
	lab._reset_gesture()
	lab.gesture_trace = true
	distance = lab.distance
	for i in 5:
		pinch(scene_point, 1.001)
	check(is_equal_approx(lab.distance, distance / pow(1.001, 5)), "small pinch updates accumulate without a dead zone")
	print("Gesture routing: %d checks, %d failures" % [checks, failures])
	lab.queue_free()
	await process_frame
	quit(1 if failures else 0)
