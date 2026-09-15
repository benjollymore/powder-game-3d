extends SceneTree
## Thermal layer plumbing: format, initialisation, exact round trip, carriage
## with moving material, regional history and the cell probe. No conduction or
## phase physics is asserted here; temperatures only move with their cells.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/thermal_state_gpu.gd -- grid=128
var sim: Node3D
var checks := 0
var failures := 0
var out_dir := "/tmp/thermal-state"
var n: int = VoxelCodec.GRID

func _initialize() -> void:
	create_timer(110.0).timeout.connect(func():
		push_error("Thermal state GPU watchdog expired")
		quit(1))
	root.get_node("TimeController").paused = true
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): out_dir = arg.trim_prefix("output_dir=")
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.rule_flags = 3 # movement only: no reactions, no decay
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

func read_thermal() -> PackedByteArray:
	await process_frame
	sim.request_thermal_readback()
	return await sim.thermal_ready

func temp_at(thermal: PackedByteArray, cell: Vector3i) -> float:
	return thermal.decode_float(VoxelCodec.index(cell.x, cell.y, cell.z) * 8)

func latent_at(thermal: PackedByteArray, cell: Vector3i) -> float:
	return thermal.decode_float(VoxelCodec.index(cell.x, cell.y, cell.z) * 8 + 4)

func set_cell(thermal: PackedByteArray, cell: Vector3i, t: float, g: float = 0.0) -> void:
	var at := VoxelCodec.index(cell.x, cell.y, cell.z) * 8
	thermal.encode_float(at, t)
	thermal.encode_float(at + 4, g)

func id_at(voxels: PackedByteArray, cell: Vector3i) -> int:
	return voxels[VoxelCodec.index(cell.x, cell.y, cell.z) * 4]

func ambient_layer() -> PackedByteArray:
	var values := PackedFloat32Array()
	values.resize(n * n * n * 2)
	for i in n * n * n:
		values[i * 2] = sim.ambient_temp
		values[i * 2 + 1] = 0.0
	return values.to_byte_array()

func count_hot(thermal: PackedByteArray, t: float) -> Array:
	var values := thermal.to_float32_array()
	var found := 0
	var first := Vector3i(-1, -1, -1)
	for i in n * n * n:
		if values[i * 2] == t:
			found += 1
			if first.x < 0:
				first = Vector3i(i % n, (i / n) % n, i / (n * n))
	return [found, first]

func probe(cell: Vector3i) -> Dictionary:
	# A ray straight down onto the cell centre from above the box, in the
	# simulator's model space (unit cube, the same frame request_surface_pick uses).
	var origin := Vector3((cell.x + 0.5) / n - 0.5, 0.55, (cell.z + 0.5) / n - 0.5)
	var results: Array = []
	sim.request_cell_probe(origin, Vector3.DOWN, func(result: Dictionary): results.append(result))
	while results.is_empty():
		await process_frame
	return results[0]

func _run() -> void:
	for i in 8:
		await process_frame
	DirAccess.make_dir_recursive_absolute(out_dir)

	# Day-1 format check: the thermal layer must bind through Texture3DRD.
	check(sim.thermal_texture_rid().is_valid(), "thermal texture exists on the render thread")
	check(sim.thermal_texture.texture_rd_rid == sim.thermal_texture_rid(), "Texture3DRD is bound to the thermal RID")
	check(sim.thermal_texture.get_format() == sim.THERMAL_IMAGE_FORMAT and sim.thermal_texture.get_width() == n
		and sim.thermal_texture.get_depth() == n, "Texture3DRD accepts R32G32_SFLOAT as FORMAT_RGF at grid extent (%d, %d)" % [sim.thermal_texture.get_format(), sim.thermal_texture.get_width()])
	var names: Array = []
	for entry in sim.authoritative_textures():
		names.append(entry.name)
	check(names == ["voxels", "thermal"], "authoritative texture list names both layers")

	# Whole-world upload without thermal bytes initialises from the element table.
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(8, 8, 8), Vector3i(24, 12, 24), Elements.Id.WALL)
	WorldBuilder.fill_box(data, Vector3i(10, 12, 10), Vector3i(14, 16, 14), Elements.Id.SAND)
	WorldBuilder.fill_box(data, Vector3i(16, 12, 16), Vector3i(20, 14, 20), Elements.Id.WATER, 200)
	var voxels := data.to_byte_array()
	sim.upload(voxels)
	var thermal := await read_thermal()
	check(thermal.size() == n * n * n * sim.THERMAL_BYTES_PER_CELL, "thermal readback has eight bytes per cell")
	var expected_wall := float(Elements.TABLE[Elements.Id.WALL].get("initial_temp", sim.ambient_temp))
	var expected_water := float(Elements.TABLE[Elements.Id.WATER].get("initial_temp", sim.ambient_temp))
	check(is_equal_approx(temp_at(thermal, Vector3i(9, 9, 9)), expected_wall) and is_equal_approx(temp_at(thermal, Vector3i(17, 12, 17)), expected_water)
		and is_equal_approx(temp_at(thermal, Vector3i(60, 60, 60)), sim.ambient_temp), "upload without thermal bytes initialises each cell from its element's initial temperature")
	var values := thermal.to_float32_array()
	var latent_zero := true
	for i in n * n * n:
		if values[i * 2 + 1] != 0.0:
			latent_zero = false
			break
	check(latent_zero, "initialised latent progress is zero everywhere")

	# Exact round trip of an explicit thermal layer.
	var pattern := ambient_layer()
	for z in range(0, n, 17):
		for y in range(0, n, 13):
			for x in range(0, n, 11):
				set_cell(pattern, Vector3i(x, y, z), 250.0 + float((x + y + z) % 97), float((x * y) % 5) * 0.25)
	sim.upload(voxels, pattern)
	var back := await read_thermal()
	check(back == pattern, "uploaded thermal bytes read back exactly")
	check(await read() == voxels, "thermal upload leaves voxel bytes exact")
	check(is_equal_approx(sim.energy_total(voxels, pattern), sim.energy_total(voxels, back)), "energy total is stable across the round trip")

	# A falling grain carries its temperature: the hot value moves with the sand id.
	var world := WorldBuilder.empty()
	var start := Vector3i(n / 2, n / 2 + 20, n / 2)
	WorldBuilder.fill_box(world, start, start + Vector3i.ONE, Elements.Id.SAND)
	var hot_layer := ambient_layer()
	set_cell(hot_layer, start, 900.0, 0.5)
	var world_bytes := world.to_byte_array()
	sim.upload(world_bytes, hot_layer)
	var before_thermal := await read_thermal()
	sim.request_ticks(12)
	await RenderingServer.frame_post_draw
	var after := await read()
	var after_thermal := await read_thermal()
	var counted := count_hot(after_thermal, 900.0)
	var landed: Vector3i = counted[1]
	check(id_at(after, start) == Elements.Id.AIR and landed.y < start.y and landed.x == start.x and landed.z == start.z, "grain fell straight down over twelve movement-only ticks (from y=%d to y=%d)" % [start.y, landed.y])
	check(counted[0] == 1 and landed.x >= 0 and id_at(after, landed) == Elements.Id.SAND, "exactly one cell is hot afterwards and it is the sand cell")
	check(is_equal_approx(temp_at(after_thermal, start), sim.ambient_temp) and latent_at(after_thermal, start) == 0.0, "the vacated cell keeps the air's temperature and zero latent")
	check(latent_at(after_thermal, landed) == 0.5, "latent progress travels with the grain too")
	check(is_equal_approx(sim.energy_total(world_bytes, before_thermal), sim.energy_total(after, after_thermal)), "moving material conserves the energy total exactly")

	# Regional history captures and restores thermal bytes with the voxels.
	sim.upload(world_bytes, hot_layer)
	var original_thermal := await read_thermal()
	var original := await read()
	var id: int = sim.begin_edit_transaction(func(_result): pass)
	var support := start - Vector3i(0, 1, 0)
	var support_points: Array[Vector3i] = [support]
	sim.record_stroke(id, support_points, 0, Elements.Id.WALL, sim.BrushMode.ONLY_AIR, 5)
	sim.finish_edit_transaction(id)
	var result: Dictionary = await sim.edit_transaction_ready
	check(result.error == "" and result.bytes == 512 * 12, "one touched tile records 512 cells at 12 bytes each")
	check(sim.restore_edit_transaction(result), "regional undo accepts the transaction")
	check(await read() == original and await read_thermal() == original_thermal, "undo restores voxel and thermal bytes exactly")
	sim.request_ticks(6)
	await RenderingServer.frame_post_draw
	var moved_thermal := await read_thermal()
	check(moved_thermal != original_thermal, "ticks after undo move the hot grain again")
	check(sim.restore_edit_transaction(result) and await read() == original and await read_thermal() == original_thermal, "restoring the same record again returns both layers to the captured state")

	# Cell probe reports the authoritative element and temperature.
	var probed := await probe(start)
	check(probed.pos == start and probed.element == Elements.Id.SAND and probed.temperature == 900.0 and probed.amount == 0, "probe under the hot grain reports Sand at 900 K (%s)" % [probed])
	var wet := WorldBuilder.empty()
	WorldBuilder.fill_box(wet, Vector3i(4, 4, 4), Vector3i(6, 6, 6), Elements.Id.WATER, 150)
	var wet_layer := ambient_layer()
	set_cell(wet_layer, Vector3i(5, 5, 5), 310.0)
	sim.upload(wet.to_byte_array(), wet_layer)
	await read()
	probed = await probe(Vector3i(5, 5, 5))
	check(probed.pos == Vector3i(5, 5, 5) and probed.element == Elements.Id.WATER and probed.temperature == 310.0 and probed.amount == 150, "probe reports water amount and temperature (%s)" % [probed])
	probed = await probe(Vector3i(n - 2, 3, n - 2))
	check(probed.pos.x == -1 and probed.element == 0, "probe through empty air misses")

	var file := FileAccess.open(out_dir.path_join("result.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "grid": n}, "\t"))
	file.close()
	print("THERMAL_STATE_CHECKS %d FAILURES %d" % [checks, failures])
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if failures else 0)
