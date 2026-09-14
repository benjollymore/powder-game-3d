extends SceneTree

const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
const Clock := preload("res://scripts/time_controller.gd")
var checks := 0
var failures := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	for axis in 3:
		var p := Vector3(0.1, 0.2, 0.3)
		p[axis] = 2.0
		var direction := Vector3.ZERO
		direction[axis] = -1.0
		var cell := Geometry.target(p, direction, axis, 7, 32)
		check(cell[axis] == 7, "all axes target exact plane cell")
		check(Geometry.target(p + direction * 0.5, direction, axis, 7, 32) == cell, "camera depth does not change target")
		check(Geometry.target(p, -direction, axis, 7, 32).x == -1, "behind-camera plane rejected")
	check(Geometry.target(Vector3.ZERO, Vector3.RIGHT, 2, 0, 32).x == -1, "parallel ray rejected")
	check(Geometry.target(Vector3(2, 2, 2), Vector3.FORWARD, 2, 10, 32).x == -1, "out-of-volume hit rejected")
	for b in [Vector3i(31, 22, 12), Vector3i(-3, -17, -12), Vector3i.ZERO, Vector3i(1, 1, 1)]:
		var line := Geometry.stroke(Vector3i.ZERO, b)
		check(line[0] == Vector3i.ZERO and line[-1] == b, "stroke retains endpoints")
		var connected := true
		for i in range(1, line.size()):
			var d: Vector3i = (line[i] - line[i - 1]).abs()
			connected = connected and d.x + d.y + d.z == 1
		check(connected, "fast diagonal stroke is face-connected at single-cell radius")
	var clock := Clock.new()
	clock.time_scale = 0.0
	clock.toggle_pause()
	check(not clock.paused and clock.time_scale == 1.0, "play resumes after zero-scale freeze")
	clock.free()
	print("Interaction CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
