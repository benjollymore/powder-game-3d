extends SceneTree
## _surface_join contract: joins never run through material neither endpoint
## touches. A solid block occupies x 60..67, y 60..67, z 32..34 on a floor whose
## top face is z = 31 (add targets at z = 32; erase hits at z = 31).
var checks := 0
var failures := 0


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])


func inside_block(c: Vector3i) -> bool:
	return c.x >= 60 and c.x < 68 and c.y >= 60 and c.y < 68 and c.z >= 32 and c.z < 35


func _initialize() -> void:
	var Sim = load("res://scripts/sim/voxel_sim.gd")
	var ERASE: int = Sim.BrushMode.ERASE
	var ADD: int = Sim.BrushMode.ONLY_AIR
	# Step in erase mode: floor top (z = 31) to block top (z = 34), same normal.
	var prev := {"target": Vector3i(50, 64, 31), "normal": Vector3i(0, 0, 1)}
	var next := {"target": Vector3i(64, 64, 34), "normal": Vector3i(0, 0, 1)}
	var join: Dictionary = Sim._surface_join(prev, next, ERASE)
	var bored: Array = []
	for c in join.centers:
		if inside_block(c) and c != next.target:
			bored.append(c)
	check(bored.is_empty() and join.centers == [next.target], "erase across a step breaks the segment instead of boring through the block (%s)" % [bored])
	# Step in add mode.
	prev = {"target": Vector3i(50, 64, 32), "normal": Vector3i(0, 0, 1)}
	next = {"target": Vector3i(64, 64, 35), "normal": Vector3i(0, 0, 1)}
	join = Sim._surface_join(prev, next, ADD)
	var solid: Array = []
	for c in join.centers:
		if inside_block(c):
			solid.append(c)
	check(solid.is_empty() and join.centers == [next.target], "add across a step keeps every centre out of the block (%s)" % [solid])
	# Opposite normals: top of a slab (z 38..40) then its underside.
	prev = {"target": Vector3i(50, 64, 40), "normal": Vector3i(0, 0, 1)}
	next = {"target": Vector3i(58, 64, 38), "normal": Vector3i(0, 0, -1)}
	join = Sim._surface_join(prev, next, ERASE)
	var through: Array = []
	for c in join.centers:
		if c.z == 39:
			through.append(c)
	check(through.is_empty() and join.centers == [next.target], "top face to underside breaks instead of boring through the slab core (%s)" % [through])
	# Convex corner in add mode: along the top plane to the edge, then down the side.
	prev = {"target": Vector3i(50, 64, 32), "normal": Vector3i(0, 0, 1)}
	next = {"target": Vector3i(68, 64, 30), "normal": Vector3i(1, 0, 0)}
	join = Sim._surface_join(prev, next, ADD)
	var corner := Vector3i(68, 64, 32)
	check(join.centers.count(corner) == 1, "convex corner cell appears exactly once (%d)" % join.centers.count(corner))
	check(not join.centers.has(prev.target), "the previous target is not re-stamped")
	check(join.centers.size() == join.axes.size(), "every centre carries the face axis of its leg")
	var legs_ok := true
	for k in join.centers.size():
		var c: Vector3i = join.centers[k]
		legs_ok = legs_ok and join.axes[k] == (2 if c.z == 32 and c.x <= 68 and k < join.centers.find(corner) + 1 else 0)
	check(legs_ok, "disc axis is the previous face's on the first leg and the new face's on the second")
	# Same face plane: a straight line without the previous target.
	prev = {"target": Vector3i(40, 40, 81), "normal": Vector3i(0, 0, 1)}
	next = {"target": Vector3i(45, 40, 81), "normal": Vector3i(0, 0, 1)}
	join = Sim._surface_join(prev, next, ADD)
	check(join.centers.size() == 5 and join.centers[0] == Vector3i(41, 40, 81) and join.centers[4] == next.target, "same-plane join is the straight line after the previous target")
	# Erase across a convex corner breaks too: a leg would cross the block edge.
	prev = {"target": Vector3i(50, 64, 31), "normal": Vector3i(0, 0, 1)}
	next = {"target": Vector3i(67, 64, 30), "normal": Vector3i(1, 0, 0)}
	join = Sim._surface_join(prev, next, ERASE)
	check(join.centers == [next.target], "erase joins never bridge different faces")
	print("Surface join: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
