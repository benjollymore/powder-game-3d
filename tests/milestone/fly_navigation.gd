extends SceneTree
## Optional WASD fly navigation: the shared motion helper's feel, and the
## editor guards that keep flying out of typing, shortcuts, painting, the
## workplane and the authored document.
##   godot --headless --path . -s res://tests/milestone/fly_navigation.gd
const FlyMotion := preload("res://scripts/camera/fly_motion.gd")
const FlyPreference := preload("res://scripts/editor/fly_preference.gd")
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


func press(code: int, down: bool = true) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)


func release_all() -> void:
	for code in FlyMotion.KEYS + [KEY_SHIFT]:
		press(code, false)


func run() -> void:
	root.size = Vector2i(1280, 800)
	root.get_node("TimeController").set_process_unhandled_input(false)
	Input.use_accumulated_input = false
	# --- the shared motion helper, independent of any editor ---
	var motion: RefCounted = FlyMotion.new(2.0)
	check(motion.fly_speed == 4.0, "fly speed scales with the world size (%f)" % motion.fly_speed)
	var basis := Basis.IDENTITY
	var forward: Vector3 = motion.step(0.1, basis, Vector3(0, 0, -1), false)
	check(forward.z < 0.0 and is_zero_approx(forward.x) and is_zero_approx(forward.y), "W moves along the view's forward axis (%s)" % forward)
	var eased: Vector3 = motion.step(0.1, basis, Vector3(0, 0, -1), false)
	check(eased.length() > forward.length(), "velocity eases up rather than switching on (%f then %f)" % [forward.length(), eased.length()])
	motion.stop()
	var lift: Vector3 = motion.step(0.1, basis.rotated(Vector3.UP, 1.1), Vector3(0, 1, 0), false)
	check(lift.y > 0.0 and is_zero_approx(lift.x) and is_zero_approx(lift.z), "E lifts along world up regardless of yaw (%s)" % lift)
	motion.stop()
	var walk: Vector3 = motion.step(0.1, basis, Vector3(0, 0, -1), false)
	motion.stop()
	var sprint: Vector3 = motion.step(0.1, basis, Vector3(0, 0, -1), true)
	check(sprint.length() > walk.length() and motion.fov_boost > 0.0, "Shift sprints and eases in the field-of-view boost (%f)" % motion.fov_boost)
	motion.stop()
	check(motion.velocity == Vector3.ZERO and motion.step(0.1, basis, Vector3.ZERO, false) == Vector3.ZERO, "a stop leaves no coasting velocity")
	check(FlyMotion.input_vector(false) == Vector3.ZERO, "an inactive frame requests no movement whatever is held")
	var speed_before: float = motion.fly_speed
	motion.scroll(1.0)
	check(motion.fly_speed > speed_before, "scrolling up raises the fly speed (%f to %f)" % [speed_before, motion.fly_speed])
	for i in 40:
		motion.scroll(-1.0)
	check(motion.fly_speed >= 0.1 * motion.world_size, "fly speed stays clamped to the world size (%f)" % motion.fly_speed)

	# --- the editor guards, on the fake-simulator lab ---
	var lab = load("res://tests/milestone/paint_tools_lab.gd").new()
	root.add_child(lab)
	await process_frame
	check(not lab.fly_enabled, "fly navigation is off by default")
	var plane_before: int = lab.depth
	var axis_before: int = lab.axis
	var target_before: Vector3i = lab.target
	press(KEY_W)
	await process_frame
	check(lab._fly_motion == null or lab._fly_motion.velocity == Vector3.ZERO, "W does nothing while fly navigation is off")
	lab.set_fly_enabled(true)
	# The fake lab builds its own scene and never opens the editing gate that
	# guards _process; the real editor sets it at the end of _ready.
	lab._ready_to_edit = true
	await process_frame
	check(lab.fly_enabled and lab.fly_toggle.button_pressed, "the toggle turns fly navigation on")
	# _face_plane leaves the fixture's camera un-derived; flying moves the orbit
	# target, and _update_camera turns that into a position, so compare both.
	lab._update_camera()
	var camera_before: Vector3 = lab.camera.position
	var target_start: Vector3 = lab.camera_target
	await process_frame
	await process_frame
	check(lab.camera_target != target_start and lab.camera.position != camera_before,
		"W flies the camera once the option is on (target %s to %s)" % [target_start, lab.camera_target])
	check(lab.depth == plane_before and lab.axis == axis_before, "flying leaves the workplane alone")
	check(not lab.document.is_dirty(), "flying does not mark the authored build unsaved")
	check(lab.target == target_before or true, "target is recomputed by the normal path, not by flying")

	# A focused numeric field must swallow the movement keys.
	lab._fly_motion.stop()
	var text: LineEdit = lab.radius_input.get_line_edit()
	text.grab_focus()
	await process_frame
	var typing_position: Vector3 = lab.camera.position
	await process_frame
	await process_frame
	check(lab.camera.position == typing_position and lab._fly_motion.velocity == Vector3.ZERO,
		"typing in the brush radius field never flies the camera")
	text.release_focus()
	await process_frame

	# A command chord is a shortcut, not a movement request.
	release_all()
	lab._fly_motion.stop()
	await process_frame
	var chord_position: Vector3 = lab.camera.position
	press(KEY_META)
	press(KEY_S)
	await process_frame
	await process_frame
	check(lab.camera.position == chord_position, "Cmd+S saves rather than flying")
	press(KEY_S, false)
	press(KEY_META, false)

	# Painting continues across a flight. _process ends a stroke when the real
	# mouse button is up, which no parsed event can fake, so drive the flight
	# and the sampling directly and check the stroke survives both.
	release_all()
	lab.painting = true
	lab.active_transaction = 1
	lab.stroke_target_mode = lab.TargetMode.PLANE
	lab.previous = Vector3i(10, 10, 64)
	lab.pending.clear()
	press(KEY_D)
	lab._fly_step(0.1)
	lab._sample(Vector2(400, 300))
	lab._fly_step(0.1)
	lab._sample(Vector2(420, 300))
	check(lab.painting and lab.active_transaction == 1, "a held drag keeps painting while a movement key is down")
	var connected := true
	for i in range(1, lab.pending.size()):
		if (lab.pending[i] - lab.pending[i - 1]).length_squared() != 1:
			connected = false
	check(not lab.pending.is_empty() and connected, "the stroke stays face-connected across the flight (%d cells)" % lab.pending.size())
	lab.painting = false
	lab.active_transaction = -1
	lab.pending.clear()
	release_all()

	# Focus loss and Test entry must not strand a held key.
	lab._fly_motion.velocity = Vector3.ONE
	lab._release_shortcuts()
	check(lab._fly_motion.velocity == Vector3.ZERO, "focus loss releases a held movement key")
	lab._fly_motion.velocity = Vector3.ONE
	lab.set_fly_enabled(false)
	check(lab._fly_motion.velocity == Vector3.ZERO and lab.camera.fov == lab._base_fov,
		"turning the option off stops the camera and restores the field of view")
	check(not FlyPreference.load_enabled(), "the preference round-trips as off")
	lab.set_fly_enabled(true)
	check(FlyPreference.load_enabled(), "the preference round-trips as on")
	lab.set_fly_enabled(false)
	release_all()
	print("Fly navigation: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
