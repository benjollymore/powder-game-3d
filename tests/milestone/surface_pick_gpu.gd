extends SceneTree
signal picked(result: Dictionary)
var lab: Node3D
var sim: Node3D
var checks := 0
var failures := 0
func _initialize() -> void:
	create_timer(60.0).timeout.connect(func():
		push_error("Surface GPU watchdog expired")
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
func ray(x: int = 64, y: int = 64, mask: int = -1, section: bool = false, depth: int = 127) -> Dictionary:
	var value := {"origin": Vector3((x + 0.5) / VoxelCodec.GRID - 0.5, (y + 0.5) / VoxelCodec.GRID - 0.5, 1.0),
		"direction": Vector3.FORWARD, "section": section, "axis": 2, "depth": depth}
	if mask >= 0:
		value.mask = mask
	return value
func query(value: Dictionary, radius: int = 0, erase: bool = false) -> Dictionary:
	sim.request_surface_pick(value, radius, erase, func(result): picked.emit(result))
	return await picked
func read() -> PackedByteArray:
	await process_frame
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready
func at(bytes: PackedByteArray, x: int, y: int, z: int) -> int:
	return bytes[VoxelCodec.index(x, y, z) * 4]
func finish(id: int) -> Dictionary:
	sim.finish_edit_transaction(id)
	return await sim.edit_transaction_ready
func _run() -> void:
	for i in 8:
		await process_frame
	sim = lab.sim
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(32, 32, 80), Vector3i(96, 96, 81), Elements.Id.WALL)
	WorldBuilder.fill_box(data, Vector3i(64, 64, 90), Vector3i(65, 65, 91), Elements.Id.WATER)
	WorldBuilder.fill_box(data, Vector3i(64, 64, 100), Vector3i(65, 65, 101), Elements.Id.SMOKE)
	sim.upload(data.to_byte_array())
	var before := await read()
	var wall_mask := 1 << Elements.Id.WALL
	var result := await query(ray())
	check(result.valid and result.hit == Vector3i(64, 64, 90), "authoritative pick includes liquid and skips gas by default")
	check(result.target == Vector3i(64, 64, 91) and result.normal == Vector3i.BACK, "add selects adjacent outside cell with outward face normal")
	result = await query(ray(64, 64, wall_mask), 3)
	check(result.hit.z == 80 and result.target.z == 81, "radius-three add sits on the selected surface (centre is the first air cell outside the hit face)")
	result = await query(ray(), 0, true)
	check(result.target == result.hit and result.element == Elements.Id.WATER, "erase targets actual hit material")
	result = await query(ray(64, 64, wall_mask))
	check(result.hit.z == 80, "explicit material mask skips intervening liquid and gas")
	result = await query(ray(64, 64, -1, true, 85))
	check(result.hit.z == 80 and result.target.z == 81, "section pick ignores hidden positive-side matter without deleting it")
	result = await query(ray(64, 64, wall_mask, true, 80))
	check(not result.valid, "add does not redirect into hidden space beyond the cut plane")
	result = await query(ray(64, 64, wall_mask, true, 80), 0, true)
	check(result.valid and result.target.z == 80, "erase can target the retained section boundary")
	var miss := ray()
	miss.origin.x = 2.0
	result = await query(miss)
	check(not result.valid, "out-of-world ray is a miss")
	miss.direction = Vector3.ZERO
	check(not (await query(miss)).valid, "invalid zero-length ray is rejected")
	check(await read() == before, "all preview picking leaves exact GPU material bytes unchanged")
	# Two fixed rays to the same planar wall must draw a connected one-cell line.
	var first := ray(40, 40, wall_mask)
	var last := ray(60, 40, wall_mask)
	last.connect = true
	var id: int = sim.begin_edit_transaction(func(_result): pass)
	var started := Time.get_ticks_usec()
	sim.record_surface_stroke(id, [first, last], 0, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 81)
	first.origin.x = 4.0 # source dictionary changes cannot alter queued gesture rays
	var transaction := await finish(id)
	print("surface two-ray transaction completion_us=", Time.get_ticks_usec() - started, " undo_bytes=", transaction.bytes)
	var after := await read()
	var connected := true
	var preserved := true
	for x in range(40, 61):
		connected = connected and at(after, x, 40, 81) == Elements.Id.SAND
		preserved = preserved and at(after, x, 40, 80) == Elements.Id.WALL
	check(connected, "fast flat-face surface stroke is connected at radius zero")
	check(preserved, "surface additive stroke preserves every underlying wall cell")
	check(transaction.bytes < 49152, "surface undo captures local tiles, not the world (12 bytes per cell with thermal)")
	sim.restore_edit_transaction(transaction)
	check(await read() == before, "surface stroke undo restores all packed bytes exactly")
	# Placement contract 1: a radius-three additive stamp forms a cap resting on
	# the surface, so at least one stamped cell is face-adjacent to the hit cell
	# and the wall underneath stays intact.
	id = sim.begin_edit_transaction(func(_result): pass)
	sim.record_surface_stroke(id, [ray(64, 64, wall_mask)], 3, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 82)
	transaction = await finish(id)
	after = await read()
	var cap := 0
	for dz in range(0, 5):
		for dy in range(-3, 4):
			for dx in range(-3, 4):
				if at(after, 64 + dx, 64 + dy, 81 + dz) == Elements.Id.SAND:
					cap += 1
	check(at(after, 64, 64, 81) == Elements.Id.SAND and at(after, 64, 64, 80) == Elements.Id.WALL,
		"radius-three add sits on the selected surface (at least one stamped cell is face-adjacent to the hit cell)")
	check(cap > 40 and cap < 123 and at(after, 64, 64, 85) == 0, "the cap is the sphere clipped by the wall, not a floating ball")
	sim.restore_edit_transaction(transaction)
	check(await read() == before, "cap stroke undo restores all packed bytes exactly")
	# Preview is informational: mutation re-picks the ordered current GPU state.
	result = await query(ray(50, 50, wall_mask))
	check(result.target.z == 81, "old preview initially sees original wall")
	sim.paint(Vector3i(50, 50, 85), 0, Elements.Id.WALL)
	sim.paint_surface_stroke([ray(50, 50, wall_mask)], 0, Elements.Id.SAND)
	after = await read()
	check(at(after, 50, 50, 86) == Elements.Id.SAND and at(after, 50, 50, 81) == Elements.Id.AIR, "live GPU stamp re-picks a newly inserted nearer surface atomically")
	# Callback acceptance rejects old gestures, edits, and reset epochs.
	lab.pick_cache.clear()
	lab.pick_intent = 5
	result = await query(ray())
	lab._receive_pick(result, lab.pick_shown_id + 1, 4) # newer id, stale intent
	check(lab.pick_cache.is_empty(), "old ray/gesture intent cannot replace newer preview")
	lab._receive_pick(result, lab.pick_shown_id, 5) # matching intent, id not newer
	check(lab.pick_cache.is_empty(), "a pick id that is not newer than the shown one cannot replace the preview")
	sim.paint(Vector3i(1, 1, 1), 0, Elements.Id.SAND)
	lab._receive_pick(result, lab.pick_shown_id + 1, 5)
	check(not lab.pick_cache.is_empty(), "an authored edit does not reject the preview: it is informational and painting re-picks (placement contract 3)")
	lab.pick_cache.clear()
	result = await query(ray())
	sim.upload(before)
	lab._receive_pick(result, lab.pick_shown_id + 1, 5)
	check(lab.pick_cache.is_empty(), "world reset epoch rejects otherwise matching preview")
	# Live preview may describe a previous tick, but never drives the actual stamp.
	lab.testing = true
	result = await query(ray())
	sim.paint(Vector3i(2, 2, 2), 0, Elements.Id.SAND)
	lab._receive_pick(result, lab.pick_shown_id + 1, 5)
	check(not lab.pick_cache.is_empty(), "live preview tolerates world evolution while atomic stamping owns correctness")
	await _test_ray_boundaries()
	if sim.has_method("set_live_emitter"):
		await _test_tick_surface_emission()
	if sim.has_method("record_surface_thermal_stroke"):
		await _test_surface_thermal()
	print("Surface GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func _test_tick_surface_emission() -> void:
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(32, 20, 32), Vector3i(96, 21, 96), Elements.Id.WALL)
	# A held surface source stamps against the surface it started on and never
	# its own output (placement contract: no self-retargeting), so over a
	# floor it deposits its cap once and then only when that cell frees. The
	# cadence is therefore checked as stamp attempts and as byte-identical
	# results across batch sizes, not as a grain count.
	var source := {"origin": Vector3(0.5 / VoxelCodec.GRID, 1.0, 0.5 / VoxelCodec.GRID), "direction": Vector3.DOWN}
	sim.seconds_per_tick = 1.0 / 120.0
	sim.upload(data.to_byte_array())
	var floor_source := source
	sim.set_live_emitter(Vector3i.ZERO, 0, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 24.0, 123, floor_source)
	sim.request_ticks(120)
	await process_frame
	sim.request_layer_counts()
	await sim.layer_counts_ready
	sim.clear_live_emitter()
	var resting := await read()
	var on_floor := 0
	for i in range(0, resting.size(), 4):
		if resting[i] == Elements.Id.SAND:
			on_floor += 1
	check(on_floor == 1, "held surface source over a floor deposits its cap once and never climbs its own output (got %d grains)" % on_floor)
	var baseline := PackedByteArray()
	for batch in [1, 3, 7]:
		sim.upload(data.to_byte_array())
		sim.set_live_emitter(Vector3i.ZERO, 0, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 24.0, 123, source)
		var ticks := 0
		while ticks < 120:
			var amount := mini(batch, 120 - ticks)
			sim.request_ticks(amount)
			ticks += amount
			await process_frame
			sim.request_layer_counts()
			await sim.layer_counts_ready
		var attempts: int = sim._rt_live_emitter_stamps
		sim.clear_live_emitter()
		var bytes := await read()
		var count := 0
		for i in range(0, bytes.size(), 4):
			if bytes[i] == Elements.Id.SAND:
				count += 1
		check(attempts == 24 and count >= 1 and count <= 24, "surface held source attempts exactly 24 tick-owned stamps over 120 ticks at batch %d (%d attempts, %d grains)" % [batch, attempts, count])
		if baseline.is_empty():
			baseline = bytes
		else:
			check(bytes == baseline, "atomic surface emission and material state are identical at batch%d" % batch)

func _test_ray_boundaries() -> void:
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(64, 64, 64), Vector3i(65, 65, 65), Elements.Id.WALL)
	sim.upload(data.to_byte_array())
	var cell_center := Vector3(64.5, 64.5, 64.5) / VoxelCodec.GRID - Vector3.ONE * 0.5
	for axis in 3:
		for sign_value in [-1, 1]:
			var normal := Vector3i.ZERO
			normal[axis] = sign_value
			var result := await query({"origin": cell_center + Vector3(normal) * 2.0, "direction": -Vector3(normal)})
			check(result.valid and result.hit == Vector3i(64, 64, 64) and result.normal == normal and result.target == Vector3i(64, 64, 64) + normal,
				"axis%d sign%d returns exact face normal and adjacent target" % [axis, sign_value])
	var result := await query({"origin": cell_center, "direction": Vector3.RIGHT})
	check(not result.valid and result.element == Elements.Id.WALL, "camera inside solid cannot invent an outside add face")
	result = await query({"origin": cell_center, "direction": Vector3.RIGHT}, 0, true)
	check(result.valid and result.target == Vector3i(64, 64, 64), "camera inside solid may erase that exact hit cell")
	data = WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(40, 39, 64), Vector3i(41, 40, 65), Elements.Id.WALL)
	WorldBuilder.fill_box(data, Vector3i(45, 45, 64), Vector3i(46, 46, 65), Elements.Id.WALL)
	sim.upload(data.to_byte_array())
	result = await query({"origin": Vector3(30.5, 30.5, 64.5) / VoxelCodec.GRID - Vector3.ONE * 0.5,
		"direction": Vector3(1, 1, 0)}, 0, true)
	check(result.valid and result.hit == Vector3i(45, 45, 64), "diagonal ray skips wall touched only at an edge")
	result = await query({"origin": Vector3(1, 1, 0), "direction": Vector3(1, -1, 0)}, 0, true)
	check(not result.valid, "ray pointing away from the volume does not produce a boundary hit")

func read_thermal() -> PackedByteArray:
	await process_frame
	sim.request_thermal_readback()
	return await sim.thermal_ready

func temp_at(thermal: PackedByteArray, cell: Vector3i) -> float:
	return thermal.decode_float(VoxelCodec.index(cell.x, cell.y, cell.z) * 8)

## Heat then cool the same surface spot through picked rays: the hit cell
## itself is the target, the brush falloff is the workplane kernel's, voxels
## are untouched, and an equal cool returns the previous temperatures.
func _test_surface_thermal() -> void:
	var n := VoxelCodec.GRID
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(32, 20, 32), Vector3i(96, 21, 96), Elements.Id.WALL)
	var voxels := data.to_byte_array()
	sim.upload(voxels)
	var before := await read_thermal()
	var top := Vector3i(64, 20, 64)
	var down := {"origin": Vector3(64.5 / n - 0.5, 0.49, 64.5 / n - 0.5), "direction": Vector3.DOWN, "connect": false}
	var id: int = sim.begin_edit_transaction(func(_result): pass)
	sim.record_surface_thermal_stroke(id, [down], 3, 40.0)
	await finish(id)
	var heated := await read_thermal()
	check(is_equal_approx(temp_at(heated, top), temp_at(before, top) + 40.0), "surface heat raises the picked hit cell by the full strength (%.2f -> %.2f)" % [temp_at(before, top), temp_at(heated, top)])
	var rim := Vector3i(66, 20, 64)
	check(temp_at(heated, rim) > temp_at(before, rim) and temp_at(heated, rim) < temp_at(heated, top), "the rim of the sphere warms less than its centre, matching the workplane falloff")
	# The sphere is centred on the hit cell exactly like a workplane stamp, so
	# the wall below and the air above receive the same falloff at the same
	# distance; pushing it inward would put the centre past a one-cell wall.
	var below := temp_at(heated, Vector3i(64, 19, 64)) - temp_at(before, Vector3i(64, 19, 64))
	var above := temp_at(heated, Vector3i(64, 21, 64)) - temp_at(before, Vector3i(64, 21, 64))
	check(below > 0.0 and is_equal_approx(below, above) and below < 40.0,
		"the sphere is centred on the hit cell: wall below and air above warm by the same falloff (%.2f / %.2f K)" % [below, above])
	check(await read() == voxels, "surface heating leaves every voxel byte untouched")
	id = sim.begin_edit_transaction(func(_result): pass)
	sim.record_surface_thermal_stroke(id, [down], 3, -40.0)
	await finish(id)
	var cooled := await read_thermal()
	check(cooled == before, "an equal surface cool restores the previous temperatures exactly")
	# A slow drag along the surface and a fast one deposit the same heat.
	var samples: Array = []
	for x in range(40, 61):
		samples.append({"origin": Vector3((x + 0.5) / n - 0.5, 0.49, 64.5 / n - 0.5), "direction": Vector3.DOWN, "connect": x > 40})
	id = sim.begin_edit_transaction(func(_result): pass)
	for sample in samples:
		sim.record_surface_thermal_stroke(id, [sample], 3, 40.0)
	await finish(id)
	var slow := await read_thermal()
	sim.upload(voxels)
	id = sim.begin_edit_transaction(func(_result): pass)
	sim.record_surface_thermal_stroke(id, [samples[0], samples[samples.size() - 1]], 3, 40.0)
	await finish(id)
	var fast := await read_thermal()
	check(slow == fast, "a slow and a fast surface heat stroke over the same path deposit identical temperatures")
