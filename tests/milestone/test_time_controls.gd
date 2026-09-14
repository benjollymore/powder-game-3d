extends SceneTree
var lab: Node3D
var clock: Node
var checks := 0
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1
func key(code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.unicode = code + 32 if code >= KEY_A and code <= KEY_Z else 0
	event.pressed = true
	root.push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)
func run() -> void:
	root.size = Vector2i(1280, 800)
	clock = root.get_node("TimeController")
	clock.set_process(false)
	clock.paused = true
	clock.reset_tick_counter()
	lab = load("res://tests/milestone/paint_tools_lab.gd").new()
	root.add_child(lab)
	await process_frame
	check(not lab.test_time_controls.visible and lab._test_phase() == "BUILD", "Build hides Test time controls and identifies its frozen phase")
	key(KEY_P)
	key(KEY_N)
	clock._process(1.0)
	check(clock.tick == 0 and clock.paused, "viewport P/N are consumed without advancing or unfreezing Build")
	lab.testing = true
	clock.paused = false
	key(KEY_P)
	check(clock.paused and lab.pause_button.text == "Resume · P" and lab._test_phase() == "TEST · PAUSED",
		"P pauses Test and exposes Resume with an explicit paused status")
	key(KEY_N)
	clock._process(0.0)
	check(clock.tick == 1 and clock.paused, "N requests exactly one authoritative tick while keeping Test paused")
	clock._process(1.0)
	check(clock.tick == 1, "single step leaves no automatic catch-up ticks")
	key(KEY_P)
	check(not clock.paused and lab._test_phase() == "TEST · RUNNING", "P resumes the same Test state")
	key(KEY_N)
	clock._process(0.0)
	check(clock.tick == 2 and clock.paused, "N while running pauses and adds one requested tick")
	lab.capturing = true
	key(KEY_P)
	key(KEY_N)
	clock._process(0.0)
	check(clock.tick == 2 and clock.paused, "busy authoring blocks both Test time actions")
	lab.capturing = false
	lab.radius_input.get_line_edit().grab_focus()
	key(KEY_P)
	key(KEY_N)
	clock._process(0.0)
	check(clock.tick == 2 and clock.paused, "numeric text focus prevents time shortcuts from leaking through GUI")
	lab.radius_input.get_line_edit().release_focus()
	lab.queue_free()
	await process_frame
	print("Test time controls CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
