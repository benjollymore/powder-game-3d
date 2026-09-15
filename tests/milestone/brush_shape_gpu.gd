extends SceneTree
## Exact changed-cell sets for the three brush shapes (docs/milestone/
## placement-brief.md contract 5) on a workplane and on a picked surface, and
## wall preservation under ONLY_AIR. The surface centre comes from the
## authoritative pick, so the expectation follows whatever placement rule the
## targeting worker lands.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/brush_shape_gpu.gd -- grid=128 output_dir=/tmp/brush-shape
signal picked(result: Dictionary)
var sim: Node3D
var checks := 0
var failures := 0
var out_dir := "/tmp/brush-shape"
var n: int = VoxelCodec.GRID
const R := 2

func _initialize() -> void:
	create_timer(90.0).timeout.connect(func():
		push_error("Brush shape GPU watchdog expired")
		quit(1))
	root.get_node("TimeController").paused = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): out_dir = arg.trim_prefix("output_dir=")
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.rule_flags = 3 | sim.RULE_NO_THERMAL
	sim.air_enabled = false
	sim.hydro_enabled = false
	root.add_child(sim)
	_run()

func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1

func read() -> PackedByteArray:
	await process_frame
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func query(ray: Dictionary, radius: int, erase: bool) -> Dictionary:
	sim.request_surface_pick(ray, radius, erase, func(result): picked.emit(result))
	return await picked

func changed_cells(before: PackedByteArray, after: PackedByteArray) -> Dictionary:
	var cells := {}
	for i in range(0, before.size(), 4):
		if before[i] != after[i] or before[i + 1] != after[i + 1] or before[i + 2] != after[i + 2] or before[i + 3] != after[i + 3]:
			var cell := i / 4
			cells[Vector3i(cell % n, (cell / n) % n, cell / (n * n))] = true
	return cells

func expected_cells(center: Vector3i, shape: int, axis: int, before: PackedByteArray) -> Dictionary:
	var cells := {}
	for dx in range(-R, R + 1):
		for dy in range(-R, R + 1):
			for dz in range(-R, R + 1):
				var d := Vector3i(dx, dy, dz)
				var inside := true
				if shape == sim.BrushShape.SPHERE:
					inside = dx * dx + dy * dy + dz * dz <= R * R
				elif shape == sim.BrushShape.DISC:
					inside = d[axis] == 0
				if not inside:
					continue
				var p := center + d
				if not VoxelCodec.in_bounds(p):
					continue
				if before[VoxelCodec.index(p.x, p.y, p.z) * 4] == 0:
					cells[p] = true
	return cells

func describe(cells: Dictionary) -> String:
	return "%d cells" % cells.size()

func _run() -> void:
	for i in 8:
		await process_frame
	DirAccess.make_dir_recursive_absolute(out_dir)
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(32, 32, 80), Vector3i(96, 96, 81), Elements.Id.WALL) # slab facing +z
	sim.upload(data.to_byte_array())
	var base := await read()
	var wall_count := 0
	for i in range(0, base.size(), 4):
		if base[i] == Elements.Id.WALL:
			wall_count += 1
	check(wall_count == 64 * 64, "fixture has a 64x64 wall slab")
	var names := ["sphere", "cube", "disc"]
	var sizes := [0, 125, 25]
	# Workplane stamps in open air, one per shape, along the y axis (disc on the y plane).
	var before := base
	for shape in 3:
		var center := Vector3i(40 + shape * 20, 40, 40)
		sim.paint(center, R, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, shape, 1)
		var after := await read()
		var got := changed_cells(before, after)
		var want := expected_cells(center, shape, 1, before)
		if shape == 0:
			sizes[0] = want.size()
		check(got.size() == want.size() and got.keys().all(func(c): return want.has(c)), "%s at radius %d on a workplane changes exactly the expected %s" % [names[shape], R, describe(want)])
		if shape == 1:
			check(got.size() == 125, "cube changes the full 5x5x5 box in open air")
		if shape == 2:
			check(got.size() == 25 and got.keys().all(func(c): return c.y == center.y), "disc changes a 5x5 square one cell thick on the workplane axis")
		before = after
	# Cube overlapping the wall slab: ONLY_AIR preserves every wall cell.
	var overlap := Vector3i(64, 64, 81)
	sim.paint(overlap, R, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, sim.BrushShape.CUBE, 2)
	var after_overlap := await read()
	var got_overlap := changed_cells(before, after_overlap)
	var want_overlap := expected_cells(overlap, sim.BrushShape.CUBE, 2, before)
	var walls_intact := true
	for i in range(0, base.size(), 4):
		if base[i] == Elements.Id.WALL and after_overlap[i] != Elements.Id.WALL:
			walls_intact = false
	check(walls_intact, "cube over the slab preserves every wall cell")
	check(got_overlap.size() == want_overlap.size() and got_overlap.keys().all(func(c): return want_overlap.has(c)), "cube over the slab fills exactly the air part of its box (%s)" % describe(want_overlap))
	before = after_overlap
	# Surface stamps: a ray straight down +z onto the slab; the centre is the authoritative pick target.
	for shape in 3:
		var x := 40 + shape * 20
		var ray := {"origin": Vector3((x + 0.5) / n - 0.5, (70 + 0.5) / n - 0.5, 1.0), "direction": Vector3.FORWARD, "section": false, "axis": 2, "depth": n - 1, "mask": 1 << Elements.Id.WALL}
		var pick := await query(ray, R, false)
		check(pick.valid and pick.normal == Vector3i.BACK, "%s surface pick hits the slab with the +z normal" % names[shape])
		sim.paint_surface_stroke([ray], R, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 7, shape)
		var after := await read()
		var got := changed_cells(before, after)
		var want := expected_cells(pick.target, shape, 2, before)
		check(got.size() == want.size() and got.keys().all(func(c): return want.has(c)), "%s surface stamp changes exactly the expected set around the pick target (%s)" % [names[shape], describe(want)])
		if shape == 2:
			check(got.keys().all(func(c): return c.z == pick.target.z), "surface disc lies flat on the picked face plane")
		before = after
	var walls_after := true
	for i in range(0, base.size(), 4):
		if base[i] == Elements.Id.WALL and before[i] != Elements.Id.WALL:
			walls_after = false
	check(walls_after, "surface stamps of every shape preserve the slab")
	var file := FileAccess.open(out_dir.path_join("brush_shape.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "sphere_cells": sizes[0]}, "\t"))
	file.close()
	print("BRUSH_SHAPE_CHECKS %d FAILURES %d" % [checks, failures])
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if failures else 0)
