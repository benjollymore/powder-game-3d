extends SceneTree
## Diagnostic: the falling-water pool fixture's energy drift and temperature
## bounds with hydro on and off, to localise a conservation defect.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/thermal_pool_probe.gd -- grid=128
var sim: Node3D

func _initialize() -> void:
	create_timer(300.0).timeout.connect(func():
		push_error("pool probe watchdog")
		quit(1))
	root.get_node("TimeController").paused = true
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.rule_flags = 3
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

func run_ticks(ticks: int) -> void:
	var remaining := ticks
	while remaining > 0:
		var batch := mini(remaining, 100)
		sim.request_ticks(batch)
		remaining -= batch
		await process_frame
		sim.request_layer_counts()
		await sim.layer_counts_ready

func _run() -> void:
	for i in 4:
		await process_frame
	var lo := Vector3i(30, 4, 30)
	var hi := Vector3i(54, 60, 54)
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, lo, Vector3i(hi.x, 30, hi.z), Elements.Id.WALL)
	WorldBuilder.fill_box(data, lo + Vector3i(2, 2, 2), Vector3i(hi.x - 2, 30, hi.z - 2), Elements.Id.AIR)
	WorldBuilder.fill_box(data, lo + Vector3i(2, 2, 2), Vector3i(hi.x - 2, 14, hi.z - 2), Elements.Id.WATER, 200)
	WorldBuilder.fill_box(data, Vector3i(38, 40, 38), Vector3i(46, 48, 46), Elements.Id.WATER, 200)
	var world := data.to_byte_array()
	var n: int = VoxelCodec.GRID
	var layer := PackedFloat32Array()
	layer.resize(n * n * n * 2)
	for i in n * n * n:
		layer[i * 2] = 293.15
	for z in range(32, 52):
		for y in range(6, 14):
			for x in range(32, 52):
				layer[VoxelCodec.index(x, y, z) * 2] = 340.0
	var thermal := layer.to_byte_array()
	for variant in [{"name": "hydro on", "hydro": true}, {"name": "hydro off", "hydro": false}, {"name": "hydro on, no air", "hydro": true, "air": false}]:
		sim.hydro_enabled = variant.hydro
		sim.air_enabled = variant.get("air", true)
		sim.upload(world, thermal)
		var before: float = sim.energy_total(world, thermal, lo, hi)
		for step in 5:
			await run_ticks(300)
			var s: Array = await state()
			var voxels: PackedByteArray = s[0]
			var th: PackedByteArray = s[1]
			var after: float = sim.energy_total(voxels, th, lo, hi)
			var max_t := 0.0
			var min_t := 1e9
			var carried := 0
			for z in range(lo.z, hi.z):
				for y in range(lo.y, hi.y):
					for x in range(lo.x, hi.x):
						var i := VoxelCodec.index(x, y, z)
						var id: int = voxels[i * 4]
						if id == Elements.Id.WATER:
							var t: float = th.decode_float(i * 8)
							max_t = maxf(max_t, t)
							min_t = minf(min_t, t)
						elif id != Elements.Id.AIR and voxels[i * 4 + 2] != 0:
							carried += 1
			print("POOL %s tick=%d drift=%s water %.2f..%.2f K carried_nonliquid=%d mass=%d" % [variant.name, (step + 1) * 300, (after - before) / before, min_t, max_t, carried, sim.mass(voxels, Elements.Id.WATER)])
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(0)
