extends SceneTree
## Build-mode surface strokes from dense pointer rays: a fast parsed drag across
## a flat wall face and around a two-face corner must leave one face-connected
## line of material, preserve every wall cell, and give the same flat-face
## result whether one or sixteen rays per frame were sampled.
var lab: Node3D
var sim: Node3D
var checks := 0
var failures := 0
var out_dir := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="):
			out_dir = arg.trim_prefix("output_dir=")
	create_timer(90.0).timeout.connect(func():
		push_error("Surface stroke GPU watchdog expired")
		quit(1))
	lab = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(lab)
	lab.set_process(false)
	_run()


func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1


## Ray straight at the front face (+z side) of the wall slab.
func front(x: float, y: float, connect: bool) -> Dictionary:
	return {"origin": Vector3((x + 0.5) / VoxelCodec.GRID - 0.5, (y + 0.5) / VoxelCodec.GRID - 0.5, 1.0),
		"direction": Vector3.FORWARD, "section": false, "axis": 2, "depth": VoxelCodec.GRID - 1,
		"mask": 1 << Elements.Id.WALL, "connect": connect}


## Ray straight down at the top face (+y side) of the wall slab.
func top(x: float, z: float, connect: bool) -> Dictionary:
	return {"origin": Vector3((x + 0.5) / VoxelCodec.GRID - 0.5, 1.0, (z + 0.5) / VoxelCodec.GRID - 0.5),
		"direction": Vector3.DOWN, "section": false, "axis": 2, "depth": VoxelCodec.GRID - 1,
		"mask": 1 << Elements.Id.WALL, "connect": connect}


func read() -> PackedByteArray:
	await process_frame
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready


func at(bytes: PackedByteArray, cell: Vector3i) -> int:
	return bytes[VoxelCodec.index(cell.x, cell.y, cell.z) * 4]


func finish(id: int) -> Dictionary:
	sim.finish_edit_transaction(id)
	return await sim.edit_transaction_ready


func changed_cells(before: PackedByteArray, after: PackedByteArray) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var n := VoxelCodec.GRID
	for z in n:
		for y in n:
			for x in n:
				var i := VoxelCodec.index(x, y, z) * 4
				if before[i] != after[i]:
					cells.append(Vector3i(x, y, z))
	return cells


## True when every changed cell is reachable from the first by face steps.
func face_connected(cells: Array[Vector3i]) -> bool:
	if cells.is_empty():
		return false
	var members := {}
	for cell in cells:
		members[cell] = true
	var seen := {cells[0]: true}
	var frontier: Array[Vector3i] = [cells[0]]
	while not frontier.is_empty():
		var cell: Vector3i = frontier.pop_back()
		for step in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]:
			var next: Vector3i = cell + step
			if members.has(next) and not seen.has(next):
				seen[next] = true
				frontier.append(next)
	return seen.size() == cells.size()


func wall_count(bytes: PackedByteArray) -> int:
	var count := 0
	for i in range(0, bytes.size(), 4):
		if bytes[i] == Elements.Id.WALL:
			count += 1
	return count


## Sample a straight pointer path in `frames` frames of `per_frame` rays each,
## exactly as the editor would flush them, and apply it as one transaction.
func stroke(rays: Array) -> Dictionary:
	var id: int = sim.begin_edit_transaction(func(_result): pass)
	sim.record_surface_stroke(id, rays, 0, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 81)
	return await finish(id)


## The same straight path at both densities: both start at t = 0 and end at
## t = 1, so only the number of intermediate rays differs.
func flat_rays(per_frame: int) -> Array:
	var rays: Array = []
	var frames := 4
	for frame in frames:
		for sample in per_frame:
			var t: float = float(frame * per_frame + sample) / float(frames * per_frame)
			rays.append(front(40.0 + 20.0 * t, 40.0, not rays.is_empty()))
	rays.append(front(60.0, 40.0, true))
	return rays


func _run() -> void:
	for i in 8:
		await process_frame
	sim = lab.sim
	var n := VoxelCodec.GRID
	var data := WorldBuilder.empty()
	# A slab whose front face is z = 80 (targets at z = 81) and top face y = 95
	# (targets at y = 96); the two meet along the edge y = 95, z = 80.
	WorldBuilder.fill_box(data, Vector3i(32, 32, 72), Vector3i(96, 96, 81), Elements.Id.WALL)
	sim.upload(data.to_byte_array())
	var before := await read()
	var walls := wall_count(before)

	# Flat face: sixteen rays per frame versus one, same straight path.
	var dense := await stroke(flat_rays(16))
	var after_dense := await read()
	var dense_cells := changed_cells(before, after_dense)
	check(face_connected(dense_cells), "sixteen rays per frame across a flat face leave one face-connected line (%d cells)" % dense_cells.size())
	var covered := true
	for x in range(40, 61):
		covered = covered and at(after_dense, Vector3i(x, 40, 81)) == Elements.Id.SAND
	check(covered, "every cell along the flat path is painted")
	check(wall_count(after_dense) == walls, "dense flat stroke preserves every wall cell")
	sim.restore_edit_transaction(dense)
	check(await read() == before, "dense stroke undo restores exact bytes")
	var sparse := await stroke(flat_rays(1))
	var after_sparse := await read()
	check(after_sparse == after_dense, "flat-face result is identical with one or sixteen rays per frame")
	sim.restore_edit_transaction(sparse)
	check(await read() == before, "sparse stroke undo restores exact bytes")

	# Corner: up the front face to the edge, then back across the top face.
	var corner_rays: Array = []
	for i in 8:
		corner_rays.append(front(64.0, 88.0 + i, not corner_rays.is_empty()))
	for i in 8:
		corner_rays.append(top(64.0, 79.0 - i, true))
	var corner := await stroke(corner_rays)
	var after_corner := await read()
	var corner_cells := changed_cells(before, after_corner)
	check(face_connected(corner_cells), "stroke around a two-face corner is one face-connected line (%d cells)" % corner_cells.size())
	check(at(after_corner, Vector3i(64, 95, 81)) == Elements.Id.SAND and at(after_corner, Vector3i(64, 96, 81)) == Elements.Id.SAND
		and at(after_corner, Vector3i(64, 96, 79)) == Elements.Id.SAND, "the line passes the diagonal edge cell outside both faces")
	var front_covered := true
	for y in range(88, 96):
		front_covered = front_covered and at(after_corner, Vector3i(64, y, 81)) == Elements.Id.SAND
	var top_covered := true
	for z in range(72, 80):
		top_covered = top_covered and at(after_corner, Vector3i(64, 96, z)) == Elements.Id.SAND
	check(front_covered and top_covered, "both faces of the corner are painted end to end")
	check(wall_count(after_corner) == walls, "corner stroke preserves every wall cell")
	var inside := false
	for cell in corner_cells:
		inside = inside or (cell.x >= 32 and cell.x < 96 and cell.y >= 32 and cell.y < 96 and cell.z >= 72 and cell.z < 81)
	check(not inside, "no material was written inside the solid")
	sim.restore_edit_transaction(corner)
	check(await read() == before, "corner stroke undo restores exact bytes")

	# A miss between two samples breaks the line instead of inventing a bridge.
	var broken: Array = [front(50.0, 50.0, false), {"origin": Vector3(2.0, 0.0, 1.0), "direction": Vector3.FORWARD,
		"section": false, "axis": 2, "depth": n - 1, "mask": 1 << Elements.Id.WALL, "connect": true}, front(60.0, 50.0, true)]
	var gap := await stroke(broken)
	var after_gap := await read()
	var gap_cells := changed_cells(before, after_gap)
	check(gap_cells.size() == 2, "a missed sample breaks the segment (only the two endpoints changed, %d cells)" % gap_cells.size())
	sim.restore_edit_transaction(gap)
	check(await read() == before, "broken stroke undo restores exact bytes")

	# A stroke never re-targets its own stamps: a slow radius-3 drag across the
	# flat face (one sample per frame, one cell apart) stays one cap thick
	# whatever its length, instead of climbing its own paint toward the camera.
	for length in [10, 30]:
		var slow: Array = []
		for i in length:
			slow.append(front(40.0 + i, 40.0, i > 0))
		var id: int = sim.begin_edit_transaction(func(_result): pass)
		sim.record_surface_stroke(id, slow, 3, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 81)
		var cap := await finish(id)
		var after_cap := await read()
		var top := 0
		for cell in changed_cells(before, after_cap):
			top = maxi(top, cell.z)
		check(top == 81 + 3, "slow radius-3 surface drag of %d samples stays one cap thick (top z %d, expected %d)" % [length, top, 84])
		check(wall_count(after_cap) == walls, "slow radius-3 drag of %d samples preserves every wall cell" % length)
		sim.restore_edit_transaction(cap)
		check(await read() == before, "slow drag undo restores exact bytes")

	# The same in Test mode: a live surface drag lays its path and the held
	# source keeps stamping, all against the surface the stroke began on.
	for length in [10, 30]:
		sim.upload(data.to_byte_array())
		await read()
		var previous_ray: Dictionary = {}
		for i in length:
			var ray := front(40.0 + i, 40.0, not previous_ray.is_empty())
			sim.queue_live_surface_path([ray], 3, Elements.Id.WALL, sim.BrushMode.ONLY_AIR, 1)
			sim.set_live_emitter(Vector3i.ZERO, 3, Elements.Id.WALL, sim.BrushMode.ONLY_AIR, 24.0, 7, ray)
			sim.request_ticks(5)
			await process_frame
			previous_ray = ray
		sim.clear_live_emitter()
		var after_live := await read()
		var top_live := 0
		var painted := 0
		for cell in changed_cells(before, after_live):
			top_live = maxi(top_live, cell.z)
			painted += 1
		check(painted > 0 and top_live == 81 + 3, "live radius-3 surface drag of %d samples stays one cap thick (top z %d, %d cells)" % [length, top_live, painted])
	sim.upload(data.to_byte_array())
	await read()

	if out_dir != "":
		DirAccess.make_dir_recursive_absolute(out_dir)
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out_dir.path_join("surface-stroke.png"))
	print("SURFACE_STROKE_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
