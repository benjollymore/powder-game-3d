extends SceneTree
## GPU regression tests. Needs a window (no RenderingDevice under --headless):
##   godot --path . --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd
## Uploads known worlds, runs ticks, reads back, asserts. Exit code 0/1.

const GRID := VoxelCodec.GRID

var _failures := 0
var _checks := 0
var _sim: Node3D


func _initialize() -> void:
	# Autoloads are not resolvable by name in a `-s` script; fetch from the tree.
	var tc := root.get_node_or_null("TimeController")
	if tc:
		tc.paused = true
	_sim = load("res://scenes/sim_volume.tscn").instantiate()
	_sim.listen_to_time_controller = false
	_sim.rule_flags = 3 # movement-only tests: no reactions, no decay
	root.add_child(_sim)
	_run()


func _run() -> void:
	# Let the render thread create the texture and pipeline.
	for i in 3:
		await process_frame
	await _test_sand_settles()
	await _test_water_levels()
	await _test_steam_rises()
	await _test_brush_paints()
	_sim.rule_flags = 0
	await _test_fire_burns_plant()
	await _test_water_boils_on_fire()
	await _test_oil_floats()
	print("%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("FAIL: " + msg)
	else:
		print("ok: " + msg)


func _empty_world() -> PackedInt32Array:
	var data := PackedInt32Array()
	data.resize(GRID * GRID * GRID)
	return data


func _fill_box(data: PackedInt32Array, lo: Vector3i, hi: Vector3i, id: int) -> void:
	for z in range(lo.z, hi.z):
		for y in range(lo.y, hi.y):
			for x in range(lo.x, hi.x):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, (x * 7 + y * 13 + z * 31) & 0xFF)


func _run_and_read(ticks: int) -> PackedByteArray:
	_sim.request_ticks(ticks)
	await process_frame
	# Lambdas capture by value in GDScript, so wait on the signal instead of a flag.
	_sim.request_readback(func(_bytes): pass)
	var bytes: PackedByteArray = await _sim.readback_ready
	return bytes


func _test_sand_settles() -> void:
	# A 16^3 sand cube floating at y=100 over an empty floor (the boundary is wall).
	var data := _empty_world()
	_fill_box(data, Vector3i(56, 100, 56), Vector3i(72, 116, 72), Elements.Id.SAND)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)

	# Grains pair with the cell below on ~half the ticks, so a 100-voxel drop
	# plus slumping needs well over 400 ticks.
	var after_bytes: PackedByteArray = await _run_and_read(1500)
	var after: PackedInt64Array = _sim.histogram(after_bytes)
	var later_bytes: PackedByteArray = await _run_and_read(300)
	check(later_bytes == after_bytes, "pile is stable: identical after 300 more ticks")

	check(before[Elements.Id.SAND] == 16 * 16 * 16, "test world has 4096 sand")
	check(after[Elements.Id.SAND] == before[Elements.Id.SAND],
		"sand count conserved: %d -> %d" % [before[Elements.Id.SAND], after[Elements.Id.SAND]])
	check(after[Elements.Id.AIR] == before[Elements.Id.AIR], "air count conserved")

	var unknown := 0
	for id in range(Elements.count(), 256):
		unknown += after[id]
	check(unknown == 0, "no unknown element ids after ticking")

	# Every sand voxel should rest on something (no air directly below), and
	# none should still be up where it started.
	var floating := 0
	var still_high := 0
	for z in GRID:
		for y in range(1, GRID):
			for x in GRID:
				if after_bytes[VoxelCodec.index(x, y, z) * 4] == Elements.Id.SAND:
					if after_bytes[VoxelCodec.index(x, y - 1, z) * 4] == Elements.Id.AIR:
						floating += 1
					if y >= 100:
						still_high += 1
	check(floating == 0, "no sand floating over air (found %d)" % floating)
	check(still_high == 0, "no sand left at the drop height (found %d)" % still_high)


func _test_water_levels() -> void:
	# Wall bowl (interior x,z in [6,42), y in [6,30)) with a 24^3 water cube above it.
	var data := _empty_world()
	_fill_box(data, Vector3i(4, 0, 4), Vector3i(44, 30, 44), Elements.Id.WALL)
	_fill_box(data, Vector3i(6, 6, 6), Vector3i(42, 30, 42), Elements.Id.AIR)
	_fill_box(data, Vector3i(10, 60, 10), Vector3i(34, 84, 34), Elements.Id.WATER)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after_bytes: PackedByteArray = await _run_and_read(4000)
	var after: PackedInt64Array = _sim.histogram(after_bytes)

	check(after[Elements.Id.WATER] == before[Elements.Id.WATER],
		"water count conserved: %d -> %d" % [before[Elements.Id.WATER], after[Elements.Id.WATER]])
	check(after[Elements.Id.WALL] == before[Elements.Id.WALL], "wall count conserved")

	# Water column height per bowl column; a level surface varies by <= 1.
	var lo := 999
	var hi := 0
	var bubbles := 0
	var outside := 0
	for z in GRID:
		for x in GRID:
			var height := 0
			for y in GRID:
				if after_bytes[VoxelCodec.index(x, y, z) * 4] == Elements.Id.WATER:
					height += 1
					if y > 0 and after_bytes[VoxelCodec.index(x, y - 1, z) * 4] == Elements.Id.AIR:
						bubbles += 1
					if not (x >= 6 and x < 42 and z >= 6 and z < 42):
						outside += 1
			if x >= 6 and x < 42 and z >= 6 and z < 42:
				lo = mini(lo, height)
				hi = maxi(hi, height)
	check(outside == 0, "all water ended inside the bowl (found %d outside)" % outside)
	check(bubbles == 0, "no water floating over air (found %d)" % bubbles)
	check(hi - lo <= 1, "water surface is level: column heights %d..%d" % [lo, hi])
	check(lo >= 6, "bowl holds a real depth of water (min column %d)" % lo)


func _test_steam_rises() -> void:
	var data := _empty_world()
	_fill_box(data, Vector3i(40, 4, 40), Vector3i(60, 24, 60), Elements.Id.STEAM)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after_bytes: PackedByteArray = await _run_and_read(1500)
	var after: PackedInt64Array = _sim.histogram(after_bytes)

	check(after[Elements.Id.STEAM] == before[Elements.Id.STEAM],
		"steam count conserved: %d -> %d" % [before[Elements.Id.STEAM], after[Elements.Id.STEAM]])
	var under_air := 0
	var low := 0
	for z in GRID:
		for y in GRID:
			for x in GRID:
				if after_bytes[VoxelCodec.index(x, y, z) * 4] == Elements.Id.STEAM:
					if y < GRID - 1 and after_bytes[VoxelCodec.index(x, y + 1, z) * 4] == Elements.Id.AIR:
						under_air += 1
					if y < GRID / 2:
						low += 1
	# A few voxels are always mid-move (just drifted sideways under an air pocket).
	check(under_air <= before[Elements.Id.STEAM] / 100, "steam has risen: %d of %d still under air" % [under_air, before[Elements.Id.STEAM]])
	check(low == 0, "no steam left in the lower half (found %d)" % low)


func _test_brush_paints() -> void:
	_sim.upload(_empty_world().to_byte_array())
	await process_frame
	_sim.paint(Vector3i(64, 64, 64), 5, Elements.Id.WALL)
	var painted: PackedByteArray = await _run_and_read(0)
	var counts: PackedInt64Array = _sim.histogram(painted)
	# Voxels with |d|^2 <= 25 around the centre.
	var expected := 0
	for z in range(-5, 6):
		for y in range(-5, 6):
			for x in range(-5, 6):
				if x * x + y * y + z * z <= 25:
					expected += 1
	check(counts[Elements.Id.WALL] == expected, "brush painted a radius-5 sphere: %d voxels (expected %d)" % [counts[Elements.Id.WALL], expected])
	_sim.paint(Vector3i(64, 64, 64), 5, Elements.Id.WALL, _sim.BrushMode.ERASE)
	var erased: PackedByteArray = await _run_and_read(0)
	check(_sim.histogram(erased)[Elements.Id.WALL] == 0, "erase mode removed the sphere")


func _test_fire_burns_plant() -> void:
	var data := _empty_world()
	_fill_box(data, Vector3i(50, 0, 50), Vector3i(70, 20, 70), Elements.Id.PLANT)
	_fill_box(data, Vector3i(46, 0, 50), Vector3i(50, 4, 54), Elements.Id.FIRE)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after: PackedInt64Array = _sim.histogram(await _run_and_read(2500))
	check(before[Elements.Id.PLANT] == 8000, "test world has 8000 plant")
	# Fire can die before reaching the last isolated slivers, so allow <1% unburnt.
	check(after[Elements.Id.PLANT] <= before[Elements.Id.PLANT] / 100,
		"fire consumed the plant block (%d of %d left)" % [after[Elements.Id.PLANT], before[Elements.Id.PLANT]])
	check(after[Elements.Id.FIRE] == 0, "fire burnt out afterwards (%d left)" % after[Elements.Id.FIRE])


func _test_water_boils_on_fire() -> void:
	var data := _empty_world()
	_fill_box(data, Vector3i(40, 0, 40), Vector3i(60, 10, 60), Elements.Id.WATER)
	_fill_box(data, Vector3i(44, 10, 44), Vector3i(56, 12, 56), Elements.Id.FIRE)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after: PackedInt64Array = _sim.histogram(await _run_and_read(200))
	var boiled: int = after[Elements.Id.STEAM]
	check(boiled > 0, "some water boiled into steam (%d)" % boiled)
	check(after[Elements.Id.WATER] + boiled == before[Elements.Id.WATER],
		"water + steam equals original water (%d + %d vs %d)" % [after[Elements.Id.WATER], boiled, before[Elements.Id.WATER]])
	check(after[Elements.Id.FIRE] == 0, "fire was put out (%d left)" % after[Elements.Id.FIRE])


func _test_oil_floats() -> void:
	_sim.rule_flags = 3
	var data := _empty_world()
	_fill_box(data, Vector3i(4, 0, 4), Vector3i(44, 40, 44), Elements.Id.WALL)
	_fill_box(data, Vector3i(6, 6, 6), Vector3i(42, 40, 42), Elements.Id.AIR)
	_fill_box(data, Vector3i(10, 8, 10), Vector3i(34, 16, 34), Elements.Id.OIL)
	_fill_box(data, Vector3i(10, 20, 10), Vector3i(34, 28, 34), Elements.Id.WATER)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after_bytes: PackedByteArray = await _run_and_read(3000)
	var after: PackedInt64Array = _sim.histogram(after_bytes)
	check(after[Elements.Id.OIL] == before[Elements.Id.OIL] and after[Elements.Id.WATER] == before[Elements.Id.WATER],
		"oil and water conserved")
	var oil_under_water := 0
	for z in range(6, 42):
		for x in range(6, 42):
			var seen_oil := false
			for y in range(6, 40):
				var id := after_bytes[VoxelCodec.index(x, y, z) * 4]
				if id == Elements.Id.OIL:
					seen_oil = true
				elif id == Elements.Id.WATER and seen_oil:
					oil_under_water += 1
	check(oil_under_water <= before[Elements.Id.OIL] / 100,
		"oil floats on water: %d water voxels above oil" % oil_under_water)
	_sim.rule_flags = 0
