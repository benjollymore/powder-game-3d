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
	# Placement contract 2: the target is the cell whose visible face the ray
	# crosses on the workplane slab, not the centre-plane intersection.
	var grid := 32
	var cell := 7
	var origin := Vector3(-0.4, 0.0, -0.2) # just in front of the slab along +z, near the left edge
	var grazing := Vector3(6.0, 0.0, -1.0).normalized() # shallow: 6 cells of x per cell of z
	var got := Geometry.target(origin, grazing, 2, cell, grid)
	var entry_z := (float(cell + 1) / grid - 0.5) # the +z face is the visible one for a ray travelling -z
	var entry := origin + grazing * ((entry_z - origin.z) / grazing.z)
	var expected := Vector3i(((entry + Vector3.ONE * 0.5) * grid).floor())
	expected.z = cell
	var centre_plane := origin + grazing * (((float(cell) + 0.5) / grid - 0.5 - origin.z) / grazing.z)
	var centre_cell := Vector3i(((centre_plane + Vector3.ONE * 0.5) * grid).floor())
	check(got == expected, "grazing ray targets the cell under the visible slab face")
	check(centre_cell.x != expected.x, "the old centre-plane rule would have chosen a different cell for this grazing ray")
	check(Geometry.target(Vector3(0.1, 0.2, 2.0), Vector3.FORWARD, 2, cell, grid) == Vector3i(int((0.1 + 0.5) * grid), int((0.2 + 0.5) * grid), cell),
		"perpendicular ray keeps the centre-plane cell")
	var inside := Vector3(0.05, 0.05, float(cell) / grid - 0.5 + 0.5 / grid) # camera inside the slab
	check(Geometry.target(inside, grazing, 2, cell, grid) == Vector3i(int((0.05 + 0.5) * grid), int((0.05 + 0.5) * grid), cell),
		"camera inside the slab targets the cell it is in")
	check(Geometry.target(Vector3(0.0, 0.0, -0.9), Vector3.FORWARD, 2, cell, grid).x == -1, "slab entirely behind the camera is rejected")
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
