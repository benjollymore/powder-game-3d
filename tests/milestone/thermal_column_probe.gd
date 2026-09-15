extends SceneTree
## Diagnostic: hydro's column remap alone. A sealed one-cell-wide water
## column (no lateral spread possible) with a linear temperature profile:
## energy must be exact and temperatures must stay within the initial range.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/thermal_column_probe.gd -- grid=128
var sim: Node3D
const N := 12

func _initialize() -> void:
	create_timer(120.0).timeout.connect(func():
		push_error("column probe watchdog")
		quit(1))
	root.get_node("TimeController").paused = true
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.rule_flags = 3
	sim.air_enabled = false
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
	var row: bool = OS.get_cmdline_user_args().has("row=1")
	var lo := Vector3i(60, 4, 60)
	var hi := Vector3i(63, 4 + N + 4, 63)
	var data := WorldBuilder.empty()
	if row:
		lo = Vector3i(60, 4, 60)
		hi = Vector3i(60 + N + 4, 8, 63)
	WorldBuilder.fill_box(data, lo, hi, Elements.Id.WALL)
	if row:
		WorldBuilder.fill_box(data, Vector3i(61, 5, 61), Vector3i(61 + N + 2, 7, 62), Elements.Id.AIR)
		for x in N:
			WorldBuilder.fill_box(data, Vector3i(61 + x, 5, 61), Vector3i(62 + x, 6, 62), Elements.Id.WATER, 255 if x % 2 == 0 else 60)
	else:
		WorldBuilder.fill_box(data, Vector3i(61, 5, 61), Vector3i(62, 5 + N + 2, 62), Elements.Id.AIR)
		WorldBuilder.fill_box(data, Vector3i(61, 5, 61), Vector3i(62, 5 + N, 62), Elements.Id.WATER, 200)
	var world := data.to_byte_array()
	var n: int = VoxelCodec.GRID
	var layer := PackedFloat32Array()
	layer.resize(n * n * n * 2)
	for i in n * n * n:
		layer[i * 2] = 293.15
	for y in N:
		if row:
			layer[VoxelCodec.index(61 + y, 5, 61) * 2] = 340.0 - 40.0 * float(y) / float(N - 1)
		else:
			layer[VoxelCodec.index(61, 5 + y, 61) * 2] = 340.0 - 40.0 * float(y) / float(N - 1)
	var thermal := layer.to_byte_array()
	for hydro in [true, false]:
		sim.hydro_enabled = hydro
		sim.upload(world, thermal)
		var before: float = sim.energy_total(world, thermal, lo, hi)
		for step in [1, 2, 10, 100, 300]:
			sim.request_ticks(step)
			await process_frame
			sim.request_layer_counts()
			await sim.layer_counts_ready
			var s: Array = await state()
			var voxels: PackedByteArray = s[0]
			var th: PackedByteArray = s[1]
			var after: float = sim.energy_total(voxels, th, lo, hi)
			var column := PackedStringArray()
			for y in N + 2:
				var i := VoxelCodec.index(61 + y, 5, 61) if row else VoxelCodec.index(61, 5 + y, 61)
				column.append("%d:%d@%.2f" % [voxels[i * 4], voxels[i * 4 + 2], th.decode_float(i * 8)])
			print("COLUMN hydro=%s ticks+%d drift=%s mass=%d | %s" % [hydro, step, (after - before) / before, sim.mass(voxels, Elements.Id.WATER), " ".join(column)])
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(0)
