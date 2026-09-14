extends "res://tests/milestone/batch_cadence.gd"
## Fixed-tick injection regression: compare actual world/mass, not CPU stamp counts.
## godot --path . --always-on-top --disable-vsync --resolution 320x240 \
##   -s res://tests/milestone/live_emitter.gd -- grid=128
const SOURCE_EVENTS := [0, 17, 38, 73]

func _run() -> void:
	_sim = load("res://scenes/sim_volume.tscn").instantiate()
	_sim.listen_to_time_controller = false
	_sim.seconds_per_tick = 1.0 / 120.0
	root.add_child(_sim)
	for i in 3:
		await process_frame
	for material in [Elements.Id.SAND, Elements.Id.WATER]:
		var reference: Dictionary = await _source_timeline([1], material)
		for schedule in [[3], [7, 2, 5, 1, 9]]:
			var actual: Dictionary = await _source_timeline(schedule, material)
			_check(actual.voxels == reference.voxels, "%s injected voxel bytes equal for %s" % [Elements.TABLE[material].name, schedule])
			_check(actual.solver == reference.solver, "all air textures equal for %s" % [schedule])
			_check(actual.mass == reference.mass, "actual accepted material mass equal for %s (%d)" % [schedule, actual.mass])
			_check(actual.stamps == reference.stamps, "scheduled source stamp count equal for %s (%d)" % [schedule, actual.stamps])
	await _source_lifecycle()
	print("LIVE_EMITTER grid=%d checks=%d failures=%d" % [VoxelCodec.GRID, _checks, _failures])
	_sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _source_timeline(schedule: Array, material: int) -> Dictionary:
	_sim.load_scenario("Empty")
	await _drain()
	var cursor := 0
	var batch_index := 0
	while cursor < TOTAL_TICKS:
		if SOURCE_EVENTS.has(cursor):
			var event_index := SOURCE_EVENTS.find(cursor)
			var center := Vector3i(VoxelCodec.GRID / 2 + event_index * 3, VoxelCodec.GRID * 3 / 4, VoxelCodec.GRID / 2)
			# Metadata updates preserve phase, including a rate change halfway.
			_sim.set_live_emitter(center, 3, material, _sim.BrushMode.ONLY_AIR, 24.0 if event_index < 2 else 36.0, 33271)
		var next_event := TOTAL_TICKS
		for event_tick in SOURCE_EVENTS:
			if event_tick > cursor:
				next_event = event_tick
				break
		var count := mini(int(schedule[batch_index % schedule.size()]), next_event - cursor)
		_sim.request_ticks(count)
		cursor += count
		batch_index += 1
		await RenderingServer.frame_post_draw
	_sim.clear_live_emitter()
	await _drain()
	_sim.request_readback(func(_bytes): pass)
	var voxels: PackedByteArray = await _sim.readback_ready
	RenderingServer.call_on_render_thread(_rt_air_snapshot)
	var solver: PackedByteArray = await air_snapshot_ready
	var mass: int = _sim.mass(voxels, material) if material == Elements.Id.WATER else _sim.histogram(voxels)[material]
	_check(mass > 0, "source injected real material")
	_check(_sim._rt_live_emitter_stamps > 10, "source emitted repeatedly between physics ticks")
	print("SOURCE material=%s schedule=%s ticks=%d mass=%d stamps=%d voxel_sha256=%s air_sha256=%s" % [Elements.TABLE[material].name, schedule, cursor, mass, _sim._rt_live_emitter_stamps, _hash(voxels), _hash(solver)])
	return {"voxels": voxels, "solver": solver, "mass": mass, "stamps": _sim._rt_live_emitter_stamps}

func _source_lifecycle() -> void:
	_sim.load_scenario("Empty")
	await _drain()
	var center := Vector3i(VoxelCodec.GRID / 2, VoxelCodec.GRID * 3 / 4, VoxelCodec.GRID / 2)
	_sim.set_live_emitter(center, 0, Elements.Id.SAND)
	await _drain()
	_check(_sim._rt_live_emitter_stamps == 0, "enabling a paused source cannot emit without a tick")
	_sim.request_ticks(1)
	await _drain()
	_check(_sim._rt_live_emitter_stamps == 1, "first source enable emits before the next tick")
	for i in 10:
		_sim.set_live_emitter(center, 0, Elements.Id.SAND)
	_sim.request_ticks(1)
	await _drain()
	_check(_sim._rt_live_emitter_stamps == 1, "repeated metadata updates cannot restart emission phase")
	_sim.clear_live_emitter()
	_sim.request_ticks(20)
	await _drain()
	_check(_sim._rt_live_emitter_stamps == 1, "releasing the source stops future injection")
	_sim.set_live_emitter(center, 0, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 1000000.0)
	_sim.request_ticks(3)
	await _drain()
	_check(_sim._rt_live_emitter_stamps == 3, "extreme rate is bounded to one source stamp per tick")
	_sim.load_scenario("Empty")
	_sim.request_ticks(10)
	await _drain()
	_check(_sim._rt_live_emitter.is_empty() and _sim._rt_live_emitter_stamps == 0, "whole-world replacement disables live source")
