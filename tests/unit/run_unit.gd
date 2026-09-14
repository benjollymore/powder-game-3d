extends SceneTree
## Headless unit tests: `godot --headless --path . -s res://tests/unit/run_unit.gd`
## Plain asserts, no plugin. Exit code 0 on success, 1 on failure.

const TimeControllerScript := preload("res://scripts/time_controller.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_time_controller()
	print("%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("FAIL: " + msg)


func _test_time_controller() -> void:
	var f := TimeControllerScript.compute_ticks
	var tps := TimeControllerScript.TICKS_PER_SECOND
	var frame := 1.0 / 60.0

	var r: Array = f.call(frame, true, 1.0, 0, 0.0)
	check(r[0] == 0, "paused runs no ticks")
	check(r[1] == 0.0, "paused does not accumulate")

	r = f.call(frame, true, 1.0, 1, 0.0)
	check(r[0] == 1, "step while paused runs exactly one tick")

	# Real time at 60 fps: 60 ticks per second.
	var acc := 0.0
	var total := 0
	for i in 60:
		r = f.call(frame, false, 1.0, 0, acc)
		total += r[0]
		acc = r[1]
	check(total >= 59 and total <= 60, "scale 1.0 at 60 fps gives ~60 ticks/s, got %d" % total)

	# Half speed: ~30 ticks per second.
	acc = 0.0
	total = 0
	for i in 60:
		r = f.call(frame, false, 0.5, 0, acc)
		total += r[0]
		acc = r[1]
	check(total >= 29 and total <= 30, "scale 0.5 gives ~30 ticks/s, got %d" % total)

	# Frozen scale runs nothing.
	r = f.call(frame, false, 0.0, 0, 0.0)
	check(r[0] == 0, "scale 0 runs no ticks")

	# Huge frame is capped and the backlog is dropped.
	r = f.call(1.0, false, 4.0, 0, 0.0)
	check(r[0] == TimeControllerScript.MAX_TICKS_PER_FRAME, "ticks per frame are capped")
	check(r[1] == 0.0, "backlog dropped after cap")
	check(tps == 60.0, "tick rate constant is 60")
