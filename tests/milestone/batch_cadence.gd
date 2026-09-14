extends SceneTree
## Exact authoritative-state regression across submission schedules.
## Run with a visible RenderingDevice window; GPU work must be serialized.
## godot --path . --always-on-top --disable-vsync --resolution 320x240 \
##   -s res://tests/milestone/batch_cadence.gd -- grid=128
signal air_snapshot_ready(bytes: PackedByteArray)

const TOTAL_TICKS := 96
const EDIT_TICKS := [0, 17, 38, 73]
var _sim: Node3D
var _checks := 0
var _failures := 0

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	call_deferred("_run")

func _run() -> void:
	_sim = load("res://scenes/sim_volume.tscn").instantiate()
	_sim.listen_to_time_controller = false
	root.add_child(_sim)
	for i in 3:
		await process_frame
	for scenario in ["Forest fire", "Steam vent"]:
		var reference: Dictionary = await _timeline(scenario, [1])
		for schedule in [[3], [7, 2, 5, 1, 9]]:
			var actual: Dictionary = await _timeline(scenario, schedule)
			_check(actual.voxels == reference.voxels, "%s voxel bytes equal for %s" % [scenario, schedule])
			_check(actual.air == reference.air, "%s velocity/heat bytes equal for %s" % [scenario, schedule])
			_check(actual.solver == reference.solver, "%s all air solver textures equal for %s" % [scenario, schedule])
	print("BATCH_CADENCE grid=%d checks=%d failures=%d" % [VoxelCodec.GRID, _checks, _failures])
	_sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _timeline(scenario: String, schedule: Array) -> Dictionary:
	_sim.load_scenario(scenario)
	await _drain()
	var cursor := 0
	var batch_index := 0
	while cursor < TOTAL_TICKS:
		if EDIT_TICKS.has(cursor):
			var index := EDIT_TICKS.find(cursor)
			var grid: int = VoxelCodec.GRID
			var center := Vector3i(grid / 2 + index * 3, grid * 3 / 4, grid / 2)
			var element: int = [Elements.Id.STEAM, Elements.Id.WATER, Elements.Id.FIRE, Elements.Id.SAND][index]
			RenderingServer.call_on_render_thread(_sim._rt_paint.bind(center, 3, element, _sim.BrushMode.REPLACE, 99173 + index))
		var next_edit := TOTAL_TICKS
		for edit_tick in EDIT_TICKS:
			if edit_tick > cursor:
				next_edit = edit_tick
				break
		# Bound batches at edit ticks: identical commands have identical
		# positions in simulation time even with an irregular submission size.
		var count := mini(int(schedule[batch_index % schedule.size()]), next_edit - cursor)
		_sim.request_ticks(count)
		cursor += count
		batch_index += 1
		await RenderingServer.frame_post_draw
	await _drain()
	_sim.request_readback(func(_bytes): pass)
	var voxels: PackedByteArray = await _sim.readback_ready
	_sim.request_velocity_readback()
	var air: PackedByteArray = await _sim.velocity_ready
	RenderingServer.call_on_render_thread(_rt_air_snapshot)
	var solver: PackedByteArray = await air_snapshot_ready
	print("STATE scenario=%s schedule=%s ticks=%d voxel_sha256=%s air_sha256=%s" % [scenario, schedule, cursor, _hash(voxels), _hash(air)])
	_check(voxels.size() == VoxelCodec.GRID * VoxelCodec.GRID * VoxelCodec.GRID * 4, "full voxel readback completed")
	_check(air.size() == _sim.AIR_GRID * _sim.AIR_GRID * _sim.AIR_GRID * 8, "full air readback completed")
	_check(solver.size() == _sim.AIR_GRID * _sim.AIR_GRID * _sim.AIR_GRID * 31, "all seven air solver textures read back")
	return {"voxels": voxels, "air": air, "solver": solver}

func _rt_air_snapshot() -> void:
	var bytes := PackedByteArray()
	for texture in [_sim._air_vel[0], _sim._air_vel[1], _sim._air_pres[0], _sim._air_pres[1], _sim._air_div, _sim._air_occ, _sim._air_src]:
		bytes.append_array(_sim._rd.texture_get_data(texture, 0))
	air_snapshot_ready.emit.call_deferred(bytes)

func _drain() -> void:
	_sim.request_layer_counts()
	await _sim.layer_counts_ready

func _hash(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if ok:
		print("ok: " + message)
	else:
		_failures += 1
		push_error(message)
