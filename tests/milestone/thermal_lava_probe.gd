extends SceneTree
## Diagnostic: water over lava, sampled every 100 ticks. Prints the hottest
## water cell, its latent progress, lava/stone/steam counts and the energy in
## the basin, to see why (or whether) boiling starts.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/thermal_lava_probe.gd -- grid=128
var sim: Node3D

func _initialize() -> void:
	create_timer(200.0).timeout.connect(func():
		push_error("lava probe watchdog")
		quit(1))
	root.get_node("TimeController").paused = true
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.rule_flags = 2
	root.add_child(sim)
	call_deferred("_run")

func state() -> Array:
	await process_frame
	var results: Array = []
	sim.state_ready.connect(func(v, t): results.append([v, t]), CONNECT_ONE_SHOT)
	sim.request_state_readback()
	while results.is_empty():
		await process_frame
	return results[0]

func _run() -> void:
	for i in 4:
		await process_frame
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(40, 4, 40), Vector3i(60, 20, 60), Elements.Id.WALL)
	WorldBuilder.fill_box(data, Vector3i(42, 6, 42), Vector3i(58, 20, 58), Elements.Id.AIR)
	WorldBuilder.fill_box(data, Vector3i(42, 6, 42), Vector3i(58, 9, 58), Elements.Id.LAVA, 200)
	WorldBuilder.fill_box(data, Vector3i(42, 9, 42), Vector3i(58, 13, 58), Elements.Id.WATER, 200)
	sim.upload(data.to_byte_array())
	var n: int = VoxelCodec.GRID
	for step in 16:
		var s: Array = await state()
		var voxels: PackedByteArray = s[0]
		var thermal: PackedByteArray = s[1]
		var hist: PackedInt64Array = sim.histogram(voxels)
		var max_water := 0.0
		var max_g := 0.0
		var min_lava := 1e9
		var max_lava := 0.0
		var water_amount_sum := 0
		for z in range(42, 58):
			for y in range(6, 20):
				for x in range(42, 58):
					var i := VoxelCodec.index(x, y, z)
					var id := voxels[i * 4]
					var t := thermal.decode_float(i * 8)
					var g := thermal.decode_float(i * 8 + 4)
					if id == Elements.Id.WATER:
						max_water = maxf(max_water, t)
						max_g = maxf(max_g, g)
						water_amount_sum += voxels[i * 4 + 2]
					elif id == Elements.Id.LAVA:
						min_lava = minf(min_lava, t)
						max_lava = maxf(max_lava, t)
		var energy: float = sim.energy_total(voxels, thermal, Vector3i(40, 4, 40), Vector3i(60, 20, 60))
		print("LAVA tick=%d water=%d (units %d) max_T=%.2f max_G=%.1f lava=%d (%.0f..%.0f K) stone=%d steam=%d energy=%.0f" % [
			sim.tick, hist[Elements.Id.WATER], water_amount_sum, max_water, max_g, hist[Elements.Id.LAVA], min_lava, max_lava, hist[Elements.Id.STONE], hist[Elements.Id.STEAM], energy])
		sim.request_ticks(100)
		await process_frame
		sim.request_layer_counts()
		await sim.layer_counts_ready
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(0)
