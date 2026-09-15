extends SceneTree
## GPU regression tests. Needs a window (no RenderingDevice under --headless):
##   godot --path . --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd
## Uploads known worlds, runs ticks, reads back, asserts. Exit code 0/1.

var GRID: int = VoxelCodec.GRID

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
	# The shadow proxy polls occupancy readbacks; its stale replies would race
	# the occupancy test's own request.
	var proxy := _sim.get_node_or_null("ShadowProxy")
	if proxy:
		proxy.set_process(false)
	_run()


func _run() -> void:
	# Let the render thread create the texture and pipeline.
	for i in 3:
		await process_frame
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("only="):
			only = arg.substr(5)
	if GRID != 128 and only == "":
		push_warning("GPU tests are authored for grid=128; running the full suite at %d will fail on coordinates" % GRID)
	# [name, rule_flags]: 3 = movement only (no reactions, no decay).
	var tests := [
		["_test_sand_settles", 3], ["_test_water_levels", 3], ["_test_steam_rises", 3],
		["_test_brush_paints", 3], ["_test_occupancy", 3], ["_test_liquid_mass", 3],
		["_test_u_bend", 3], ["_test_pressure_pipe", 3], ["_test_density_pass", 3],
		["_test_fire_burns_plant", 0], ["_test_water_boils_on_fire", 0], ["_test_oil_floats", 3],
		["_test_air_boundary", 3], ["_test_air_plume", 2], ["_test_splats", 3], ["_test_sprites", 3],
		["_test_gas_ignites", 0], ["_test_gunpowder_flash", 0], ["_test_acid_dissolves_sand", 0],
		["_test_clone_emits", 0], ["_test_void_sinks", 0], ["_test_wax_melts_on_fire", 0],
		["_test_large_grid_smoke", 0],
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
	return WorldBuilder.empty()


func _fill_box(data: PackedInt32Array, lo: Vector3i, hi: Vector3i, id: int, amount: int = -1) -> void:
	WorldBuilder.fill_box(data, lo, hi, id, amount)


## Amount-weighted water height of column (x, z), in cells.
func _column_height(bytes: PackedByteArray, x: int, z: int, id: int) -> float:
	var total := 0
	for y in GRID:
		var base := VoxelCodec.index(x, y, z) * 4
		if bytes[base] == id:
			total += mini(bytes[base + 2], Elements.LIQUID_FULL)
	return float(total) / Elements.LIQUID_FULL


func _run_and_read(ticks: int) -> PackedByteArray:
	# Chunk the work across frames so no single submission trips the GPU fence
	# timeout (first runs after a shader reimport also pay Metal pipeline compiles).
	var remaining := ticks
	while remaining > 0:
		var batch := mini(remaining, 100)
		_sim.request_ticks(batch)
		remaining -= batch
		await process_frame
		# A tiny synchronous readback per batch keeps the GPU queue to one batch;
		# otherwise batches pile up faster than they run and the big readback's
		# fence wait (1 s) times out, returning zeros.
		_sim.request_layer_counts()
		await _sim.layer_counts_ready
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
	var mid := Vector3i.ONE * (GRID / 2)
	_sim.paint(mid, 5, Elements.Id.WALL)
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
	_sim.paint(mid, 5, Elements.Id.WALL, _sim.BrushMode.ERASE)
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


# --- heat milestone, tranche B elements ------------------------------------------

func _test_gas_ignites() -> void:
	# Gas sealed in a box with a flame at the top: it rises into the flame and
	# every cell flashes (FIRE + GAS at p = 1).
	var data := _empty_world()
	_fill_box(data, Vector3i(40, 4, 40), Vector3i(72, 40, 72), Elements.Id.WALL)
	_fill_box(data, Vector3i(42, 6, 42), Vector3i(70, 38, 70), Elements.Id.AIR)
	_fill_box(data, Vector3i(44, 6, 44), Vector3i(68, 16, 68), Elements.Id.GAS)
	_fill_box(data, Vector3i(52, 34, 52), Vector3i(60, 38, 60), Elements.Id.FIRE)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after: PackedInt64Array = _sim.histogram(await _run_and_read(1500))
	check(before[Elements.Id.GAS] == 24 * 10 * 24, "test world has 5760 gas")
	check(after[Elements.Id.GAS] <= before[Elements.Id.GAS] / 100, "gas flashed into flame (%d of %d left)" % [after[Elements.Id.GAS], before[Elements.Id.GAS]])
	check(after[Elements.Id.WALL] == before[Elements.Id.WALL], "wall untouched by the flash")


func _test_gunpowder_flash() -> void:
	# A spark at one end of a trail on the floor burns the whole trail.
	var data := _empty_world()
	_fill_box(data, Vector3i(10, 4, 60), Vector3i(100, 6, 64), Elements.Id.GUNPOWDER)
	_fill_box(data, Vector3i(6, 4, 58), Vector3i(10, 8, 66), Elements.Id.FIRE)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after: PackedInt64Array = _sim.histogram(await _run_and_read(2500))
	check(before[Elements.Id.GUNPOWDER] == 90 * 2 * 4, "test world has 720 gunpowder")
	check(after[Elements.Id.GUNPOWDER] <= before[Elements.Id.GUNPOWDER] / 50, "flash consumed the trail (%d of %d left)" % [after[Elements.Id.GUNPOWDER], before[Elements.Id.GUNPOWDER]])


func _test_acid_dissolves_sand() -> void:
	# Acid poured onto sand in a wall bowl eats sand and thins; the bowl is immune.
	var data := _empty_world()
	_fill_box(data, Vector3i(40, 4, 40), Vector3i(80, 40, 80), Elements.Id.WALL)
	_fill_box(data, Vector3i(42, 6, 42), Vector3i(78, 40, 78), Elements.Id.AIR)
	_fill_box(data, Vector3i(42, 6, 42), Vector3i(78, 14, 78), Elements.Id.SAND)
	_fill_box(data, Vector3i(50, 20, 50), Vector3i(70, 30, 70), Elements.Id.ACID)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var acid_before: int = _sim.mass(world, Elements.Id.ACID)
	var bytes: PackedByteArray = await _run_and_read(1500)
	var after: PackedInt64Array = _sim.histogram(bytes)
	check(before[Elements.Id.SAND] == 36 * 8 * 36, "test world has 10368 sand")
	check(after[Elements.Id.SAND] < before[Elements.Id.SAND] * 9 / 10, "acid dissolved over a tenth of the sand (%d of %d left)" % [after[Elements.Id.SAND], before[Elements.Id.SAND]])
	check(_sim.mass(bytes, Elements.Id.ACID) < acid_before, "acid thinned as it ate (%d -> %d units)" % [acid_before, _sim.mass(bytes, Elements.Id.ACID)])
	check(after[Elements.Id.WALL] == before[Elements.Id.WALL], "wall is immune to acid")
	check(after[Elements.Id.SMOKE] + after[Elements.Id.AIR] > before[Elements.Id.SMOKE] + before[Elements.Id.AIR], "dissolved sand left smoke or cleared air")


func _test_clone_emits() -> void:
	# A capped clone tray seeded with water underneath keeps producing water.
	var data := _empty_world()
	_fill_box(data, Vector3i(50, 60, 50), Vector3i(70, 62, 70), Elements.Id.WALL)
	_fill_box(data, Vector3i(50, 58, 50), Vector3i(70, 60, 70), Elements.Id.CLONE)
	_fill_box(data, Vector3i(50, 57, 50), Vector3i(70, 58, 70), Elements.Id.WATER)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var bytes: PackedByteArray = await _run_and_read(600)
	var after: PackedInt64Array = _sim.histogram(bytes)
	check(after[Elements.Id.CLONE] == before[Elements.Id.CLONE], "clone cells persist (%d)" % after[Elements.Id.CLONE])
	check(_sim.mass(bytes, Elements.Id.WATER) > _sim.mass(world, Elements.Id.WATER) * 2, "clone multiplied the seed water (%d -> %d units)" % [_sim.mass(world, Elements.Id.WATER), _sim.mass(bytes, Elements.Id.WATER)])
	var stray := 0
	for id in Elements.count():
		if id != Elements.Id.AIR and id != Elements.Id.WALL and id != Elements.Id.CLONE and id != Elements.Id.WATER:
			stray += after[id]
	check(stray == 0, "clone emits only the material it was armed with (%d stray cells)" % stray)


func _test_void_sinks() -> void:
	# Water dropped onto a void slab vanishes; the slab persists.
	var data := _empty_world()
	_fill_box(data, Vector3i(40, 4, 40), Vector3i(80, 6, 80), Elements.Id.VOID)
	_fill_box(data, Vector3i(50, 20, 50), Vector3i(70, 36, 70), Elements.Id.WATER)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after: PackedInt64Array = _sim.histogram(await _run_and_read(1500))
	check(before[Elements.Id.WATER] == 20 * 16 * 20, "test world has 6400 water")
	check(after[Elements.Id.WATER] == 0, "void swallowed all the water (%d left)" % after[Elements.Id.WATER])
	check(after[Elements.Id.VOID] == before[Elements.Id.VOID], "void slab persists")


func _test_wax_melts_on_fire() -> void:
	# Placeholder until temperature-driven phase change lands: the interim
	# FIRE + WAX contact rule must melt some of a pillar under a flame.
	var data := _empty_world()
	_fill_box(data, Vector3i(56, 4, 56), Vector3i(72, 30, 72), Elements.Id.WAX)
	_fill_box(data, Vector3i(60, 30, 60), Vector3i(68, 36, 68), Elements.Id.FIRE)
	var world := data.to_byte_array()
	_sim.upload(world)
	var before: PackedInt64Array = _sim.histogram(world)
	var after: PackedInt64Array = _sim.histogram(await _run_and_read(600))
	check(after[Elements.Id.WAX] < before[Elements.Id.WAX], "flame melted some wax (%d of %d left)" % [after[Elements.Id.WAX], before[Elements.Id.WAX]])
	check(after[Elements.Id.WAX] + after[Elements.Id.MOLTEN_WAX] >= before[Elements.Id.WAX] * 9 / 10, "wax mostly melted rather than vanished")


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
	var half := GRID / 2
	_sim.paint(Vector3i(half, half, half), 5, Elements.Id.WALL)
	await process_frame
	_sim.request_occupancy_readback()
	var occ: PackedByteArray = await _sim.occupancy_ready
	var n: int = _sim.OCCUPANCY_GRID
	check(occ.size() == n * n * n * 4, "occupancy readback is %d bytes (RGBA)" % occ.size())
	# The sphere straddles the two bricks either side of the centre on every axis.
	var b := half / 8
	var set_count := 0
	var wrong := 0
	var fluid_set := 0
	for i in occ.size() / 4:
		var x := i % n
		var y := (i / n) % n
		var z := i / (n * n)
		var expected := (x == b - 1 or x == b) and (y == b - 1 or y == b) and (z == b - 1 or z == b)
		if occ[i * 4] != 0:
			set_count += 1
		if (occ[i * 4] != 0) != expected:
			wrong += 1
		if occ[i * 4 + 1] != 0:
			fluid_set += 1
	check(fluid_set == 0, "no fluid bricks flagged for a wall sphere (%d)" % fluid_set)
	# A water sphere elsewhere marks the fluid channel, not the solid one.
	_sim.paint(Vector3i(16, 16, 16), 5, Elements.Id.WATER)
	await process_frame
	_sim.request_occupancy_readback()
	occ = await _sim.occupancy_ready
	var water_brick := (2 + n * (2 + n * 2)) * 4
	check(occ[water_brick + 1] != 0 and occ[water_brick] == 0, "water sphere flags the fluid channel only (%d, %d)" % [occ[water_brick], occ[water_brick + 1]])
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


func _test_density_pass() -> void:
	var data := _empty_world()
	_fill_box(data, Vector3i(8, 8, 8), Vector3i(12, 12, 12), Elements.Id.WALL)
	_fill_box(data, Vector3i(20, 8, 8), Vector3i(26, 14, 14), Elements.Id.SAND)
	_fill_box(data, Vector3i(30, 10, 10), Vector3i(32, 12, 12), Elements.Id.WATER, 200)
	_fill_box(data, Vector3i(40, 10, 10), Vector3i(42, 12, 12), Elements.Id.WATER, 100)
	_fill_box(data, Vector3i(50, 10, 10), Vector3i(52, 12, 12), Elements.Id.WATER, 50)
	_fill_box(data, Vector3i(60, 10, 10), Vector3i(62, 12, 12), Elements.Id.STEAM)
	_sim.upload(data.to_byte_array())
	await process_frame
	await process_frame
	_sim.request_density_readback()
	var den: PackedByteArray = await _sim.density_ready
	# texture_get_data returns every mip level of the layer; mip 0 comes first.
	check(den.size() >= GRID * GRID * GRID * 4, "fields readback holds at least mip 0 (%d bytes)" % den.size())
	var at := func(x: int) -> int: return den[VoxelCodec.index(x, 10, 10) * 4]
	var g := func(x: int) -> int: return den[VoxelCodec.index(x, 10, 10) * 4 + 1]
	check(g.call(10) == 255 and g.call(23) == 255, "wall and sand interior are opaque in the smoothed field (%d, %d)" % [g.call(10), g.call(23)])
	check(g.call(12) == 0, "air beside a wall stays 0 in the smoothed field (walls do not smooth)")
	check(g.call(26) > 10 and g.call(26) < 128, "air beside sand gets a partial smoothed value (%d)" % g.call(26))
	check(g.call(25) > 128 and g.call(25) < 255, "sand surface cell is partially smoothed (%d)" % g.call(25))
	# Mip 1 follows mip 0 in the readback: the sand block's interior texel there is opaque too.
	var h := GRID / 2
	var mip1 := GRID * GRID * GRID * 4
	var m1 := func(x: int, y: int, z: int) -> int: return den[mip1 + (x + h * (y + h * z)) * 4 + 1]
	check(den.size() >= mip1 + h * h * h * 4, "readback includes mip 1")
	check(m1.call(11, 5, 5) > 200, "mip 1 sand interior is opaque (%d)" % m1.call(11, 5, 5))
	check(m1.call(30, 5, 5) == 0, "mip 1 air is empty (%d)" % m1.call(30, 5, 5))
	check(m1.call(5, 5, 5) == 255, "mip 1 wall interior is opaque (%d)" % m1.call(5, 5, 5))
	check(at.call(5) == 0, "air density 0 (got %d)" % at.call(5))
	check(at.call(10) == 255, "wall density 255 (got %d)" % at.call(10))
	check(at.call(20) == 255, "sand density 255 (got %d)" % at.call(20))
	check(at.call(30) == 255, "full water density 255 (got %d)" % at.call(30))
	check(absi(at.call(40) - 128) <= 1, "half water density ~128 (got %d)" % at.call(40))
	check(absi(at.call(50) - 85) <= 1, "quarter water density ~85 (got %d)" % at.call(50))
	check(at.call(60) == 0, "steam density 0 (got %d)" % at.call(60))


func _air_cell_stats(vel: PackedByteArray, lo: Vector3i, hi: Vector3i) -> Dictionary:
	var sum := Vector3.ZERO
	var n := 0
	var max_abs := Vector3.ZERO
	for z in range(lo.z, hi.z):
		for y in range(lo.y, hi.y):
			for x in range(lo.x, hi.x):
				var v: Vector4 = _sim.velocity_at(vel, x, y, z)
				sum += Vector3(v.x, v.y, v.z)
				max_abs = max_abs.max(Vector3(v.x, v.y, v.z).abs())
				n += 1
	return {"mean": sum / maxf(n, 1), "max_abs": max_abs}


func _steam_stats(bytes: PackedByteArray) -> Dictionary:
	var sum := Vector3.ZERO
	var sum2 := Vector3.ZERO
	var n := 0
	for i in GRID * GRID * GRID:
		if bytes[i * 4] == Elements.Id.STEAM:
			var x := i % GRID
			var y := (i / GRID) % GRID
			var z := i / (GRID * GRID)
			var p := Vector3(x, y, z)
			sum += p
			sum2 += p * p
			n += 1
	var mean := sum / maxf(n, 1)
	var var_ := sum2 / maxf(n, 1) - mean * mean
	return {"n": n, "centroid": mean, "spread_xz": sqrt(maxf(var_.x, 0.0) + maxf(var_.z, 0.0))}


func _test_air_boundary() -> void:
	# A thick solid slab: air cells fully inside it must hold exactly zero velocity,
	# and the whole simulation must be deterministic from a given upload.
	var data := _empty_world()
	_fill_box(data, Vector3i(0, 0, 0), Vector3i(GRID, 48, GRID), Elements.Id.WALL)
	_fill_box(data, Vector3i(40, 48, 40), Vector3i(56, 56, 56), Elements.Id.FIRE)
	_fill_box(data, Vector3i(30, 70, 30), Vector3i(70, 90, 70), Elements.Id.STEAM)
	var world := data.to_byte_array()
	_sim.rule_flags = 2 # keep fire alive
	_sim.upload(world)
	var first: PackedByteArray = await _run_and_read(120)
	_sim.request_velocity_readback()
	var vel: PackedByteArray = await _sim.velocity_ready
	var inside := _air_cell_stats(vel, Vector3i(0, 0, 0), Vector3i(_sim.AIR_GRID, 11, _sim.AIR_GRID))
	check(inside["max_abs"] == Vector3.ZERO, "air velocity is exactly zero inside solids (max %s)" % [inside["max_abs"]])
	var above := _air_cell_stats(vel, Vector3i(10, 12, 10), Vector3i(14, 16, 14))
	check(above["mean"].y > 0.02, "air rises above the fire (mean v_y %.3f)" % above["mean"].y)
	_sim.upload(world)
	var second: PackedByteArray = await _run_and_read(120)
	check(first == second, "simulation is deterministic from the same upload")


func _test_air_plume() -> void:
	# Fire on the floor under a steam cube: the cube should rise and spread out.
	var data := _empty_world()
	WorldBuilder.floor(data)
	_fill_box(data, Vector3i(56, 4, 56), Vector3i(72, 12, 72), Elements.Id.FIRE)
	_fill_box(data, Vector3i(56, 30, 56), Vector3i(72, 46, 72), Elements.Id.STEAM)
	var world := data.to_byte_array()
	var before := _steam_stats(world)
	_sim.upload(world)
	# Velocity is checked early, while the plume is still developing; once the
	# closed box has heated through, circulation cancels the mean updraft.
	await _run_and_read(120)
	_sim.request_velocity_readback()
	var vel_early: PackedByteArray = await _sim.velocity_ready
	var after_bytes: PackedByteArray = await _run_and_read(280)
	var after := _steam_stats(after_bytes)
	check(after["n"] == before["n"], "steam count conserved in the plume (%d -> %d)" % [before["n"], after["n"]])
	check(after["centroid"].y > before["centroid"].y + 20.0,
		"steam plume rose (centroid y %.1f -> %.1f)" % [before["centroid"].y, after["centroid"].y])
	check(after["spread_xz"] > before["spread_xz"] * 1.3,
		"plume spread sideways (xz spread %.1f -> %.1f)" % [before["spread_xz"], after["spread_xz"]])
	var col := _air_cell_stats(vel_early, Vector3i(14, 3, 14), Vector3i(18, 12, 18))
	check(col["mean"].y > 0.05, "updraft above the fire (mean v_y %.3f)" % col["mean"].y)
	_sim.request_velocity_readback()
	var vel: PackedByteArray = await _sim.velocity_ready
	var all := _air_cell_stats(vel, Vector3i(0, 1, 0), Vector3i(_sim.AIR_GRID, _sim.AIR_GRID, _sim.AIR_GRID))
	check(all["max_abs"].x > 0.02 or all["max_abs"].z > 0.02,
		"flow recirculates sideways somewhere (max |v_x| %.3f, |v_z| %.3f)" % [all["max_abs"].x, all["max_abs"].z])


## Only meaningful at grid >= 256: the demo world survives ticking without
## losing mass or producing unknown ids. Sampled every 64th voxel so the
## GDScript loop over 16.7M cells stays under a few seconds.
func _test_large_grid_smoke() -> void:
	if GRID < 256:
		print("skipped (grid %d)" % GRID)
		return
	var world := Scenarios.build("Demo")
	_sim.upload(world)
	var sand_before := 0
	var n := GRID * GRID * GRID
	for i in range(0, n, 64):
		if world[i * 4] == Elements.Id.SAND:
			sand_before += 1
	var after: PackedByteArray = await _run_and_read(40)
	var sand_after := 0
	var unknown := 0
	for i in range(0, n, 64):
		var id := after[i * 4]
		if id == Elements.Id.SAND:
			sand_after += 1
		if id >= Elements.count():
			unknown += 1
	check(after.size() == n * 4, "large grid readback is %d bytes" % after.size())
	check(unknown == 0, "no unknown ids at %d^3" % GRID)
	check(absi(sand_after - sand_before) < sand_before / 10, "sampled sand count stays close at %d^3 (%d -> %d)" % [GRID, sand_before, sand_after])


func _test_splats() -> void:
	# A sand ball dropped from height emits airborne-grain splats while falling
	# and none once the pile has settled.
	var data := _empty_world()
	WorldBuilder.floor(data)
	WorldBuilder.fill_sphere(data, Vector3(GRID / 2, GRID * 0.7, GRID / 2), 8.0, Elements.Id.SAND)
	_sim.upload(data.to_byte_array())
	await _run_and_read(6)
	_sim.request_splat_count()
	var falling: int = await _sim.splat_count_ready
	check(falling > 50, "falling sand emits splats (%d)" % falling)
	await _run_and_read(2500)
	_sim.request_splat_count()
	var settled: int = await _sim.splat_count_ready
	check(settled == 0, "a settled pile emits no splats (%d)" % settled)


func _layer_counts() -> PackedInt32Array:
	_sim.request_layer_counts()
	return await _sim.layer_counts_ready


func _test_sprites() -> void:
	# Leaves grow on exposed plant, thin falling water becomes droplets, water
	# that lands sets the landed bits, and fire feeds the FX pool with embers.
	var data := _empty_world()
	WorldBuilder.floor(data)
	WorldBuilder.fill_sphere(data, Vector3(GRID / 2, 30, GRID / 2), 10.0, Elements.Id.PLANT)
	WorldBuilder.fill_box(data, Vector3i(20, 16, 20), Vector3i(21, 40, 21), Elements.Id.WATER)
	_sim.upload(data.to_byte_array())
	await _run_and_read(2)
	var counts := await _layer_counts()
	check(counts[1] > 200, "exposed plant grows leaf cards (%d)" % counts[1])
	check(counts[2] >= 20, "a thin falling stream is drawn as droplets (%d)" % counts[2])
	check(counts[5] == 0, "no fx particles without fire or impacts (%d)" % counts[5])
	# Landed bits: read the column every few ticks until the stream has come to rest.
	var seen_landed := false
	for i in 80:
		var bytes := await _run_and_read(2)
		for y in range(4, 12):
			var w := bytes[VoxelCodec.index(20, y, 20) * 4 + 3]
			if bytes[VoxelCodec.index(20, y, 20) * 4] == Elements.Id.WATER and (w >> 1) & 3 != 0:
				seen_landed = true
		if seen_landed:
			break
	check(seen_landed, "liquid that comes to rest carries the landed bits")
	# Foam: a falling block of water fills fields.A; calm water has none.
	data = _empty_world()
	WorldBuilder.floor(data)
	WorldBuilder.fill_box(data, Vector3i(40, 40, 40), Vector3i(48, 52, 48), Elements.Id.WATER)
	WorldBuilder.fill_bowl(data, Vector3i(70, 4, 70), Vector3i(100, 30, 100), 2)
	WorldBuilder.fill_box(data, Vector3i(72, 6, 72), Vector3i(98, 20, 98), Elements.Id.WATER)
	_sim.upload(data.to_byte_array())
	for i in 30:
		await _run_and_read(1)
	_sim.request_density_readback()
	var fields: PackedByteArray = await _sim.density_ready
	var foam_falling := 0
	for y in range(4, 53):
		foam_falling = maxi(foam_falling, fields[VoxelCodec.index(44, y, 44) * 4 + 3])
	var foam_calm := fields[VoxelCodec.index(85, 12, 85) * 4 + 3]
	check(foam_falling > 150, "falling water is frothy in fields.A (%d)" % foam_falling)
	check(foam_calm < 30, "calm water carries no froth (%d)" % foam_calm)

	data = _empty_world()
	WorldBuilder.floor(data)
	WorldBuilder.fill_box(data, Vector3i(30, 4, 30), Vector3i(100, 8, 100), Elements.Id.FIRE)
	_sim.upload(data.to_byte_array())
	for i in 4:
		await _run_and_read(2)
	counts = await _layer_counts()
	check(counts[5] > 0, "fire feeds embers into the fx pool (%d alive)" % counts[5])
	check(counts[1] == 0, "no leaves without plant (%d)" % counts[1])
