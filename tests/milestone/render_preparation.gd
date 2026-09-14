extends "res://tests/milestone/batch_cadence.gd"
## Opt-in derived preparation coalescing, ordering and readback barriers.
signal preparation_ready(state: Dictionary)

func _run() -> void:
	_sim = load("res://scenes/sim_volume.tscn").instantiate()
	_sim.listen_to_time_controller = false
	root.add_child(_sim)
	for i in 3:
		await process_frame
	var baseline := await _ordered_transaction(false)
	var deferred := await _ordered_transaction(true)
	_check(baseline.voxels == deferred.voxels, "coalescing preserves ordered edit/tick voxel bytes")
	_check(baseline.air == deferred.air, "coalescing preserves all seven air solver textures")
	_check(baseline.preparations == 7, "immediate control records seven separate preparations")
	_check(deferred.preparations == 1, "same transaction prepares derived state exactly once")
	await _paused_frame()
	await _readback_barriers()
	await _mode_switch()
	print("RENDER_PREPARATION grid=%d checks=%d failures=%d" % [VoxelCodec.GRID, _checks, _failures])
	_sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _ordered_transaction(deferred: bool) -> Dictionary:
	_sim.defer_render_preparation = deferred
	_sim.load_scenario("Demo")
	await _drain()
	var before: int = _sim._rt_render_preparation_count
	for i in 4:
		RenderingServer.call_on_render_thread(_sim._rt_paint.bind(Vector3i(50 + i, 90, 60), 3, Elements.Id.SAND, _sim.BrushMode.ONLY_AIR, 881 + i))
	_sim.request_ticks(2)
	RenderingServer.call_on_render_thread(_sim._rt_paint.bind(Vector3i(54, 88, 60), 3, Elements.Id.WATER, _sim.BrushMode.ONLY_AIR, 991))
	_sim.request_ticks(1)
	# Public inspection flushes pending derived data even before viewport drawing.
	_sim.request_readback(func(_bytes): pass)
	var voxels: PackedByteArray = await _sim.readback_ready
	RenderingServer.call_on_render_thread(_rt_air_snapshot)
	var air: PackedByteArray = await air_snapshot_ready
	var preparations: int = _sim._rt_render_preparation_count - before
	print("PREPARATION variant=%s rebuilds=%d voxel_sha256=%s air_sha256=%s" % ["deferred" if deferred else "immediate", preparations, _hash(voxels), _hash(air)])
	return {"voxels": voxels, "air": air, "preparations": preparations}

func _paused_frame() -> void:
	_sim.clear()
	await _drain()
	var before: int = _sim._rt_render_preparation_count
	RenderingServer.call_on_render_thread(_sim._rt_paint.bind(Vector3i(24, 24, 24), 3, Elements.Id.WALL, _sim.BrushMode.REPLACE, 1))
	await RenderingServer.frame_post_draw
	# No force-flush in this probe: it verifies the frame's own pre-draw scheduler.
	RenderingServer.call_on_render_thread(_rt_preparation_state)
	var state: Dictionary = await preparation_ready
	_check(not state.dirty and state.count == before + 1, "paused edit publishes via pre-draw preparation without inspection")
	_check(_sim.tick == 0, "paused rendering does not schedule simulation ticks")

func _readback_barriers() -> void:
	_sim.clear()
	await _drain()
	RenderingServer.call_on_render_thread(_sim._rt_paint.bind(Vector3i(24, 24, 24), 3, Elements.Id.WALL, _sim.BrushMode.REPLACE, 1))
	_sim.request_density_readback()
	var fields: PackedByteArray = await _sim.density_ready
	_check(fields[VoxelCodec.index(24, 24, 24) * 4 + 1] == 255, "density inspection sees pending edit after implicit flush")
	_sim.clear()
	RenderingServer.call_on_render_thread(_sim._rt_paint.bind(Vector3i(24, 24, 24), 3, Elements.Id.PLANT, _sim.BrushMode.REPLACE, 1))
	_sim.request_layer_counts()
	var counts: PackedInt32Array = await _sim.layer_counts_ready
	_check(counts[1] > 0, "sprite inspection flushes pending edit and emits physical leaves")

func _mode_switch() -> void:
	_sim.load_scenario("Forest fire")
	_sim.request_ticks(3)
	_sim.defer_render_preparation = false
	_sim.request_layer_counts()
	await _sim.layer_counts_ready
	_check(_sim._rt_pending_fx_ticks == 0 and not _sim._rt_derived_dirty, "disabling coalescing flushes pending presentation time")
	_check(not _sim._rt_defer_render_preparation, "mode change is applied in render-thread command order")
	_sim.defer_render_preparation = true
	_sim.request_ticks(2)
	_sim.clear()
	_sim.request_readback(func(_bytes): pass)
	var bytes: PackedByteArray = await _sim.readback_ready
	var empty := PackedByteArray()
	empty.resize(bytes.size())
	_check(bytes == empty and _sim._rt_pending_fx_ticks == 0, "world replacement discards pending old-world time and geometry")
	_sim.flush_render_preparation()
	await _drain()
	_check(_sim._frame == 0, "empty extra flush cannot advance presentation clock")

func _rt_preparation_state() -> void:
	preparation_ready.emit.call_deferred({"dirty": _sim._rt_derived_dirty, "count": _sim._rt_render_preparation_count})
