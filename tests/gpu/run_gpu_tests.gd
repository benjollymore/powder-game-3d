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
	root.add_child(_sim)
	_run()


func _run() -> void:
	# Let the render thread create the texture and pipeline.
	for i in 3:
		await process_frame
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("only="):
			only = arg.substr(5)
	# [name, rule_flags]: 3 = movement only (no reactions, no decay).
	var tests := [
		["_test_sand_settles", 3], ["_test_water_levels", 3], ["_test_steam_rises", 3],
		["_test_brush_paints", 3], ["_test_occupancy", 3], ["_test_liquid_mass", 3],
		["_test_u_bend", 3], ["_test_pressure_pipe", 3],
		["_test_fire_burns_plant", 0], ["_test_water_boils_on_fire", 0], ["_test_oil_floats", 3],
	]
	for t in tests:
		if only != "":
			var wanted := false
			for part in only.split(","):
				if (t[0] as String).contains(part):
					wanted = true
			if not wanted:
				continue
		_sim.rule_flags = t[1]
		print("--- " + t[0])
		await call(t[0])
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


func _fill_box(data: PackedInt32Array, lo: Vector3i, hi: Vector3i, id: int, amount: int = -1) -> void:
	if amount < 0:
		amount = Elements.default_amount(id)
	for z in range(lo.z, hi.z):
		for y in range(lo.y, hi.y):
			for x in range(lo.x, hi.x):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, (x * 7 + y * 13 + z * 31) & 0xFF, amount)


## Amount-weighted water height of column (x, z), in cells.
func _column_height(bytes: PackedByteArray, x: int, z: int, id: int) -> float:
	var total := 0
	for y in GRID:
		var base := VoxelCodec.index(x, y, z) * 4
		if bytes[base] == id:
			total += mini(bytes[base + 2], Elements.LIQUID_FULL)
	return float(total) / Elements.LIQUID_FULL


func _run_and_read(ticks: int) -> PackedByteArray:
	# Chunk the work across frames so no single submission trips the GPU fence timeout.
	var remaining := ticks
	while remaining > 0:
		var batch := mini(remaining, 200)
		_sim.request_ticks(batch)
		remaining -= batch
		await process_frame
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
	var before_mass: int = _sim.mass(world, Elements.Id.WATER)
	var after_bytes: PackedByteArray = await _run_and_read(4000)
	var after: PackedInt64Array = _sim.histogram(after_bytes)

	check(_sim.mass(after_bytes, Elements.Id.WATER) == before_mass,
		"water mass conserved: %d -> %d" % [before_mass, _sim.mass(after_bytes, Elements.Id.WATER)])
	check(after[Elements.Id.WALL] == 40 * 40 * 30 - 36 * 36 * 24, "wall count conserved")

	var lo := 1e9
	var hi := 0.0
	var over_air := 0
	var outside := 0
	for z in GRID:
		for x in GRID:
			var inside := x >= 6 and x < 42 and z >= 6 and z < 42
			for y in range(1, GRID):
				if after_bytes[VoxelCodec.index(x, y, z) * 4] == Elements.Id.WATER:
					if not inside:
						outside += 1
					if after_bytes[VoxelCodec.index(x, y - 1, z) * 4] == Elements.Id.AIR:
						over_air += 1
			if inside:
				var h := _column_height(after_bytes, x, z, Elements.Id.WATER)
				lo = minf(lo, h)
				hi = maxf(hi, h)
	check(outside == 0, "all water ended inside the bowl (found %d outside)" % outside)
	check(over_air <= after[Elements.Id.WATER] / 200, "no water hanging over air (found %d)" % over_air)
	check(hi - lo <= 1.5, "water surface is level: column heights %.2f..%.2f" % [lo, hi])
	check(lo >= 9.0, "bowl holds a real depth of water (min column %.2f)" % lo)


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
	var mass_before: int = _sim.mass(world, Elements.Id.WATER)
	var after_bytes: PackedByteArray = await _run_and_read(200)
	var after: PackedInt64Array = _sim.histogram(after_bytes)
	var boiled: int = after[Elements.Id.STEAM]
	var lost: int = mass_before - _sim.mass(after_bytes, Elements.Id.WATER)
	check(boiled > 0, "some water boiled into steam (%d)" % boiled)
	# Each boiled cell removes between 1 and 255 units of water.
	check(lost >= boiled and lost <= boiled * 255, "water mass lost matches boiled cells (%d units, %d cells)" % [lost, boiled])
	check(after[Elements.Id.FIRE] == 0, "fire was put out (%d left)" % after[Elements.Id.FIRE])


func _test_oil_floats() -> void:
	var data := _empty_world()
	_fill_box(data, Vector3i(4, 0, 4), Vector3i(44, 40, 44), Elements.Id.WALL)
	_fill_box(data, Vector3i(6, 6, 6), Vector3i(42, 40, 42), Elements.Id.AIR)
	_fill_box(data, Vector3i(10, 8, 10), Vector3i(34, 16, 34), Elements.Id.OIL)
	_fill_box(data, Vector3i(10, 20, 10), Vector3i(34, 28, 34), Elements.Id.WATER)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after_bytes: PackedByteArray = await _run_and_read(3000)
	check(_sim.mass(after_bytes, Elements.Id.OIL) == _sim.mass(world, Elements.Id.OIL)
		and _sim.mass(after_bytes, Elements.Id.WATER) == _sim.mass(world, Elements.Id.WATER),
		"oil and water mass conserved")
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


func _test_occupancy() -> void:
	_sim.upload(_empty_world().to_byte_array())
	await process_frame
	_sim.paint(Vector3i(64, 64, 64), 5, Elements.Id.WALL)
	await process_frame
	_sim.request_occupancy_readback()
	var occ: PackedByteArray = await _sim.occupancy_ready
	var n: int = _sim.OCCUPANCY_GRID
	check(occ.size() == n * n * n, "occupancy readback is %d bytes" % occ.size())
	# Voxels 59..69 span bricks 7 and 8 on every axis: exactly 8 bricks set.
	var set_count := 0
	var wrong := 0
	for i in occ.size():
		var x := i % n
		var y := (i / n) % n
		var z := i / (n * n)
		var expected := (x == 7 or x == 8) and (y == 7 or y == 8) and (z == 7 or z == 8)
		if occ[i] != 0:
			set_count += 1
		if (occ[i] != 0) != expected:
			wrong += 1
	check(set_count == 8 and wrong == 0, "occupancy marks exactly the 8 bricks around the sphere (%d set, %d wrong)" % [set_count, wrong])


func _test_liquid_mass() -> void:
	# Bowl, a water cube with mixed fill levels, and a sand block dropped on top.
	var data := _empty_world()
	_fill_box(data, Vector3i(4, 0, 4), Vector3i(44, 30, 44), Elements.Id.WALL)
	_fill_box(data, Vector3i(6, 6, 6), Vector3i(42, 30, 42), Elements.Id.AIR)
	_fill_box(data, Vector3i(10, 40, 10), Vector3i(34, 64, 34), Elements.Id.WATER, 200)
	_fill_box(data, Vector3i(14, 44, 14), Vector3i(30, 60, 30), Elements.Id.WATER, 90)
	_fill_box(data, Vector3i(18, 48, 18), Vector3i(26, 56, 26), Elements.Id.WATER, 30)
	_fill_box(data, Vector3i(18, 80, 18), Vector3i(28, 90, 28), Elements.Id.SAND)
	var world := data.to_byte_array()
	_sim.upload(world)
	var mass_before: int = _sim.mass(world, Elements.Id.WATER)
	var before: PackedInt64Array = _sim.histogram(world)
	var after_bytes: PackedByteArray = await _run_and_read(3000)
	var after: PackedInt64Array = _sim.histogram(after_bytes)
	var mass_after: int = _sim.mass(after_bytes, Elements.Id.WATER)
	check(mass_after == mass_before, "liquid mass conserved with mixed fills: %d -> %d" % [mass_before, mass_after])
	check(after[Elements.Id.SAND] == before[Elements.Id.SAND], "sand count conserved through water")
	var bad_nonliquid := 0
	var zero_liquid := 0
	var remnants := 0
	for i in GRID * GRID * GRID:
		var id := after_bytes[i * 4]
		var amount := after_bytes[i * 4 + 2]
		if id == Elements.Id.WATER:
			if amount == 0:
				zero_liquid += 1
			elif amount < 6:
				remnants += 1
		elif amount != 0:
			bad_nonliquid += 1
	check(bad_nonliquid == 0, "non-liquids carry no amount (found %d)" % bad_nonliquid)
	check(zero_liquid == 0, "no water cell at zero amount (found %d)" % zero_liquid)
	check(remnants <= after[Elements.Id.WATER] / 200, "few tiny remnants (%d of %d)" % [remnants, after[Elements.Id.WATER]])


func _test_u_bend() -> void:
	# Two 6-wide arms joined by a channel at the bottom; only the left arm is filled.
	var data := _empty_world()
	_fill_box(data, Vector3i(20, 0, 20), Vector3i(60, 40, 32), Elements.Id.WALL)
	_fill_box(data, Vector3i(24, 6, 23), Vector3i(30, 40, 29), Elements.Id.AIR)   # left arm
	_fill_box(data, Vector3i(50, 6, 23), Vector3i(56, 40, 29), Elements.Id.AIR)   # right arm
	_fill_box(data, Vector3i(24, 6, 23), Vector3i(56, 8, 29), Elements.Id.AIR)    # channel, 2 tall
	_fill_box(data, Vector3i(24, 8, 23), Vector3i(30, 34, 29), Elements.Id.WATER)
	var world := data.to_byte_array()
	_sim.upload(world)
	var mass_before: int = _sim.mass(world, Elements.Id.WATER)
	var after_bytes: PackedByteArray = await _run_and_read(4000)
	check(_sim.mass(after_bytes, Elements.Id.WATER) == mass_before, "u-bend mass conserved")
	var left := 0.0
	var right := 0.0
	for z in range(23, 29):
		for x in range(24, 30):
			left += _column_height(after_bytes, x, z, Elements.Id.WATER)
		for x in range(50, 56):
			right += _column_height(after_bytes, x, z, Elements.Id.WATER)
	left /= 36.0
	right /= 36.0
	check(absf(left - right) <= 2.0, "u-bend arms level out: left %.2f, right %.2f" % [left, right])
	check(right > 4.0, "water actually crossed to the right arm (%.2f)" % right)


func _test_pressure_pipe() -> void:
	# Open tank 26 deep; a 1x1 pipe leaves the tank floor and rises outside it.
	var data := _empty_world()
	_fill_box(data, Vector3i(20, 0, 20), Vector3i(46, 40, 46), Elements.Id.WALL)
	_fill_box(data, Vector3i(22, 6, 22), Vector3i(44, 40, 44), Elements.Id.AIR)
	_fill_box(data, Vector3i(22, 6, 22), Vector3i(44, 32, 44), Elements.Id.WATER)
	_fill_box(data, Vector3i(46, 0, 20), Vector3i(51, 60, 25), Elements.Id.WALL)   # pipe casing
	_fill_box(data, Vector3i(44, 6, 22), Vector3i(49, 7, 23), Elements.Id.AIR)     # floor channel
	_fill_box(data, Vector3i(48, 6, 22), Vector3i(49, 60, 23), Elements.Id.AIR)    # riser
	var world := data.to_byte_array()
	_sim.upload(world)
	var mass_before: int = _sim.mass(world, Elements.Id.WATER)
	var after_bytes: PackedByteArray = await _run_and_read(4000)
	check(_sim.mass(after_bytes, Elements.Id.WATER) == mass_before, "pressure pipe mass conserved")
	var tank := 0.0
	for z in range(22, 44):
		for x in range(22, 44):
			tank += _column_height(after_bytes, x, z, Elements.Id.WATER)
	tank /= 22.0 * 22.0
	var pipe := _column_height(after_bytes, 48, 22, Elements.Id.WATER)
	var dbg := PackedStringArray()
	for x in range(40, 49):
		dbg.append("(%d,6)=%d" % [x, after_bytes[VoxelCodec.index(x, 6, 22) * 4 + 2]])
	for y in range(6, 14):
		dbg.append("(48,%d)=%d" % [y, after_bytes[VoxelCodec.index(48, y, 22) * 4 + 2]])
	dbg.append("tank bottom (30,6)=%d top (30,%d)=%d" % [after_bytes[VoxelCodec.index(30, 6, 30) * 4 + 2], int(tank) + 5, after_bytes[VoxelCodec.index(30, int(tank) + 5, 30) * 4 + 2]])
	print("amounts: " + " ".join(dbg))
	check(pipe >= tank - 3.0 and pipe <= tank + 2.0,
		"pressure pushes water up the pipe to the tank level: pipe %.2f vs tank %.2f" % [pipe, tank])
