extends "res://tests/milestone/batch_cadence.gd"
## Press/release before a tick remains one bounded, frozen, tick-owned click.

func _run() -> void:
	_sim = load("res://scenes/sim_volume.tscn").instantiate()
	_sim.listen_to_time_controller = false
	root.add_child(_sim)
	for i in 3:
		await process_frame
	await _distinct_clicks()
	await _frozen_surface()
	await _release_after_emission()
	await _cancel_and_reset()
	await _queue_bound()
	var one: PackedByteArray = await _batch_clicks([1])
	var three: PackedByteArray = await _batch_clicks([3])
	var irregular: PackedByteArray = await _batch_clicks([7, 2, 5, 1])
	_check(one == three and one == irregular, "queued clicks and held source preserve voxel bytes across batch schedules")
	print("LIVE_CLICK grid=%d checks=%d failures=%d" % [VoxelCodec.GRID, _checks, _failures])
	_sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _distinct_clicks() -> void:
	_sim.clear()
	await _drain()
	_sim.set_live_emitter(Vector3i(40, 90, 40), 0, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 24.0, 11)
	_sim.finish_live_emitter()
	_sim.set_live_emitter(Vector3i(70, 90, 70), 1, Elements.Id.WATER, _sim.BrushMode.ONLY_AIR, 24.0, 12)
	_sim.finish_live_emitter()
	await _drain()
	_check(_sim._rt_pending_live_clicks.size() == 2 and _sim.tick == 0, "two quick releases queue two clicks without advancing time")
	_check(_sim._rt_live_emitter.is_empty(), "release ends continuous emission")
	var before: PackedByteArray = await _voxels()
	_check(_sim.histogram(before)[Elements.Id.SAND] == 0 and _sim.mass(before, Elements.Id.WATER) == 0, "queued clicks do not paint before their tick")
	_sim.request_ticks(1)
	var after: PackedByteArray = await _voxels()
	_check(_sim.histogram(after)[Elements.Id.SAND] == 1, "first click keeps its sand material and one-cell radius")
	_check(_sim.mass(after, Elements.Id.WATER) == 1400, "second click keeps its water material and radius-one volume")
	_check(_sim._rt_live_click_stamps == 2 and _sim._rt_pending_live_clicks.is_empty(), "each queued click is consumed once")
	_sim.request_ticks(10)
	var later: PackedByteArray = await _voxels()
	_check(_sim.histogram(later)[Elements.Id.SAND] == 1 and _sim.mass(later, Elements.Id.WATER) == 1400, "completed quick clicks do not continue emitting")

func _frozen_surface() -> void:
	_sim.clear()
	var surface := {"origin": Vector3(0.5, 0.4, 0.3), "direction": Vector3.DOWN}
	_sim.set_live_emitter(Vector3i(40, 90, 40), 2, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 24.0, 121, surface)
	_sim.finish_live_emitter()
	surface["origin"] = Vector3.ZERO
	surface["direction"] = Vector3.UP
	await _drain()
	var frozen: Dictionary = _sim._rt_pending_live_clicks[0]
	_check(frozen.surface.origin == Vector3(0.5, 0.4, 0.3) and frozen.surface.direction == Vector3.DOWN, "released click retains a deep copy of its original ray metadata")
	_check(frozen.radius == 2 and frozen.element == Elements.Id.SAND and frozen.seed == 121, "released click freezes radius, material and seed")
	_sim.clear()

func _release_after_emission() -> void:
	_sim.clear()
	_sim.set_live_emitter(Vector3i(40, 90, 40), 0, Elements.Id.SAND)
	_sim.request_ticks(1)
	_sim.finish_live_emitter()
	_sim.request_ticks(10)
	var bytes: PackedByteArray = await _voxels()
	_check(_sim.histogram(bytes)[Elements.Id.SAND] == 1 and _sim._rt_live_click_stamps == 0, "release after initial source tick cannot add a duplicate click")

func _cancel_and_reset() -> void:
	_sim.clear()
	_sim.set_live_emitter(Vector3i(40, 90, 40), 0, Elements.Id.SAND)
	_sim.clear_live_emitter()
	_sim.request_ticks(1)
	var canceled: PackedByteArray = await _voxels()
	_check(_sim.histogram(canceled)[Elements.Id.SAND] == 0, "navigation/cancel can discard an unstarted source")
	for replacement in ["clear", "upload", "preset"]:
		_sim.set_live_emitter(Vector3i(40, 90, 40), 0, Elements.Id.SAND)
		_sim.finish_live_emitter()
		if replacement == "clear":
			_sim.clear()
		elif replacement == "upload":
			_sim.upload(WorldBuilder.empty().to_byte_array())
		else:
			_sim.load_scenario("Empty")
		_sim.request_ticks(2)
		var bytes: PackedByteArray = await _voxels()
		_check(_sim.histogram(bytes)[Elements.Id.SAND] == 0 and _sim._rt_pending_live_clicks.is_empty(), "%s cancels pending click before next world tick" % replacement)

func _queue_bound() -> void:
	_sim.clear()
	for i in _sim.MAX_PENDING_LIVE_CLICKS + 1:
		_sim.set_live_emitter(Vector3i(8 + i * 2, 90, 40), 0, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 24.0, i + 1)
		_sim.finish_live_emitter()
	await _drain()
	_check(_sim._rt_pending_live_clicks.size() == 32, "overflow preserves first 32 clicks and rejects newest with warning")
	_sim.request_ticks(1)
	var first: PackedByteArray = await _voxels()
	_check(_sim._rt_live_click_stamps == 4 and _sim.histogram(first)[Elements.Id.SAND] == 4, "one tick drains at most four queued clicks")
	_check(_sim._rt_pending_live_clicks.size() == 28, "remaining clicks retain FIFO order for future ticks")
	_sim.request_ticks(7)
	var all: PackedByteArray = await _voxels()
	_check(_sim._rt_live_click_stamps == 32 and _sim.histogram(all)[Elements.Id.SAND] == 32, "accepted bounded queue drains exactly once per click")

func _batch_clicks(schedule: Array) -> PackedByteArray:
	_sim.load_scenario("Empty")
	for i in 7:
		_sim.set_live_emitter(Vector3i(30 + i * 3, 90, 40), 1, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 24.0, i + 1)
		_sim.finish_live_emitter()
	_sim.set_live_emitter(Vector3i(70, 90, 70), 2, Elements.Id.WATER, _sim.BrushMode.ONLY_AIR, 24.0, 912)
	var cursor := 0
	var index := 0
	while cursor < 30:
		var count := mini(int(schedule[index % schedule.size()]), 30 - cursor)
		_sim.request_ticks(count)
		cursor += count
		index += 1
		await RenderingServer.frame_post_draw
	_sim.clear_live_emitter()
	return await _voxels()

func _voxels() -> PackedByteArray:
	_sim.request_readback(func(_bytes): pass)
	return await _sim.readback_ready
