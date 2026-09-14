extends SceneTree
## Headless unit tests: `godot --headless --path . -s res://tests/unit/run_unit.gd`
## Plain asserts, no plugin. Exit code 0 on success, 1 on failure.

const TimeControllerScript := preload("res://scripts/time_controller.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_time_controller()
	_test_liquid_constants()
	_test_scenarios()
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

	# Real time at 60 fps: TICKS_PER_SECOND ticks per second.
	var acc := 0.0
	var total := 0
	for i in 60:
		r = f.call(frame, false, 1.0, 0, acc)
		total += r[0]
		acc = r[1]
	check(absf(total - tps) <= 1.0, "scale 1.0 at 60 fps gives ~%d ticks/s, got %d" % [tps, total])

	# Half speed.
	acc = 0.0
	total = 0
	for i in 60:
		r = f.call(frame, false, 0.5, 0, acc)
		total += r[0]
		acc = r[1]
	check(absf(total - tps / 2.0) <= 1.0, "scale 0.5 gives ~%d ticks/s, got %d" % [tps / 2, total])

	# Frozen scale runs nothing.
	r = f.call(frame, false, 0.0, 0, 0.0)
	check(r[0] == 0, "scale 0 runs no ticks")

	# Huge frame is capped and the backlog is dropped.
	r = f.call(1.0, false, 4.0, 0, 0.0)
	check(r[0] == TimeControllerScript.MAX_TICKS_PER_FRAME, "ticks per frame are capped")
	check(r[1] == 0.0, "backlog dropped after cap")
	check(tps >= 60.0, "tick rate constant is at least 60")


func _test_liquid_constants() -> void:
	var glsl := FileAccess.get_file_as_string("res://shaders/compute/sim.glsl")
	check(glsl.contains("const uint FULL = %du;" % Elements.LIQUID_FULL),
		"sim.glsl FULL matches Elements.LIQUID_FULL")
	check(VoxelCodec.amount_of(VoxelCodec.encode(3, 77, 200)) == 200, "amount round-trips through encode")
	check(VoxelCodec.element_id(VoxelCodec.encode(3, 77, 200)) == 3, "id survives amount packing")
	check(VoxelCodec.seed_of(VoxelCodec.encode(3, 77, 200)) == 77, "seed survives amount packing")


func _test_scenarios() -> void:
	var n := VoxelCodec.GRID
	for name in Scenarios.names():
		var t0 := Time.get_ticks_msec()
		var bytes := Scenarios.build(name)
		var ms := Time.get_ticks_msec() - t0
		check(bytes.size() == n * n * n * 4, "scenario '%s' has the right size" % name)
		check(ms < 1000, "scenario '%s' builds in under a second (%d ms)" % [name, ms])
		var nonair := 0
		for i in range(0, bytes.size(), 4 * 64):
			if bytes[i] != 0:
				nonair += 1
		check(nonair > 0, "scenario '%s' is not empty" % name)
