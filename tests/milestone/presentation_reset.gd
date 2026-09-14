extends SceneTree
## GPU regressions for fresh authored restores and time-neutral render refresh.
## godot --path . --always-on-top --disable-vsync --resolution 320x240 \
##   -s res://tests/milestone/presentation_reset.gd -- grid=128
signal snapshot_ready(state: Dictionary)
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
	await _test_time_neutral_refresh()
	await _test_physical_sprites()
	await _test_paused_fx()
	await _test_authored_restore()
	print("PRESENTATION_RESET grid=%d checks=%d failures=%d" % [VoxelCodec.GRID, _checks, _failures])
	_sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _calm_world() -> PackedByteArray:
	var world := WorldBuilder.empty()
	WorldBuilder.floor(world)
	WorldBuilder.fill_box(world, Vector3i(16, 4, 16), Vector3i(32, 20, 32), Elements.Id.WATER)
	return world.to_byte_array()

func _test_time_neutral_refresh() -> void:
	_sim.upload(_calm_world())
	RenderingServer.call_on_render_thread(_rt_seed_foam)
	var initial := await _snapshot()
	var at := VoxelCodec.index(24, 10, 24) * 4 + 3
	_check(initial.fields[at] == 128, "fixture starts with half-intensity persistent foam")
	RenderingServer.call_on_render_thread(_rt_refresh.bind(8, 0.0))
	var refreshed := await _snapshot()
	_check(initial.fields == refreshed.fields, "eight zero-time refreshes preserve exact density/foam/mip bytes")
	_check(initial.voxels == refreshed.voxels and initial.air == refreshed.air, "render refresh leaves all physical state unchanged")
	_check(initial.clock == refreshed.clock, "zero-time refresh does not change presentation seed clock")
	RenderingServer.call_on_render_thread(_rt_refresh.bind(1, 0.16))
	var aged := await _snapshot()
	_check(absi(aged.fields[at] - 64) <= 1, "foam decays by half after 0.16 simulated seconds")
	_check(initial.voxels == aged.voxels and initial.air == aged.air, "foam aging does not mutate physical state")
	RenderingServer.call_on_render_thread(_rt_refresh.bind(4, 0.0))
	var after := await _snapshot()
	_check(after.fields == aged.fields, "paused refresh cannot continue aging foam")

func _test_physical_sprites() -> void:
	# These flags represent authoritative airborne state. Even with no time
	# advancement, the volume excludes them and the sprite layers must draw them.
	var world := WorldBuilder.empty()
	WorldBuilder.floor(world)
	WorldBuilder.fill_sphere(world, Vector3(24, 24, 24), 4.0, Elements.Id.PLANT)
	world[VoxelCodec.index(48, 40, 40)] = VoxelCodec.encode(Elements.Id.SAND, 1) | (2 << 24)
	world[VoxelCodec.index(56, 40, 40)] = VoxelCodec.encode(Elements.Id.WATER, 2, 200) | (1 << 24)
	_sim.upload(world.to_byte_array())
	var state := await _snapshot()
	_check(state.counters.decode_u32(0) == 1, "zero-time refresh emits the required airborne grain")
	_check(state.counters.decode_u32(4) > 0, "zero-time refresh emits required plant leaves")
	_check(state.counters.decode_u32(8) == 1, "zero-time refresh emits the required thin-liquid droplet")
	_check(state.counters.decode_u32(12) == 0 and state.counters.decode_u32(20) == 0, "physical sprites do not require cosmetic FX advancement")
	_check(_sim.tick == 0 and state.clock == 0, "physical representation is complete while paused")

func _test_paused_fx() -> void:
	await _warm_fire()
	var before := await _snapshot()
	_check(before.counters.decode_u32(5 * 4) > 0, "fixture has live FX particles")
	_check(not _all_zero(before.fx), "fixture has a populated FX pool")
	RenderingServer.call_on_render_thread(_rt_refresh.bind(5, 0.0))
	var after := await _snapshot()
	_check(before.fx == after.fx and before.fx_instances == after.fx_instances, "paused render refresh neither integrates nor reseeds FX")
	_check(before.counters.decode_u32(5 * 4) == after.counters.decode_u32(5 * 4), "paused refresh preserves live-FX count")
	_check(after.counters.decode_u32(3 * 4) == 0, "geometry-only refresh creates no FX spawn requests")
	_check(before.clock == after.clock and after.clock == _sim.tick, "presentation seeds use absolute simulation tick")
	_check(before.voxels == after.voxels and before.air == after.air, "paused FX refresh preserves authoritative world")

func _test_authored_restore() -> void:
	var authored := _calm_world()
	_sim.upload(authored)
	var fresh := await _snapshot()
	await _warm_fire()
	_sim.upload(authored)
	var restored := await _snapshot()
	_check(restored.voxels == authored, "Return/upload restores exact authored packed bytes")
	_check(restored.fields == fresh.fields, "authored restore discards old foam and reconstructs all field mips")
	_check(restored.air == fresh.air and _all_zero(restored.air), "authored restore clears all seven air solver textures")
	_check(_all_zero(restored.fx) and _all_zero(restored.fx_instances), "authored restore clears FX pool and displayed instances")
	_check(_all_zero(restored.spawns), "authored restore clears old spawn records")
	_check(restored.clock == 0 and _sim.tick == 0, "authored restore resets requested and presentation tick clocks")
	await _warm_fire()
	_sim.clear()
	var cleared := await _snapshot()
	_check(_all_zero(cleared.voxels) and _all_zero(cleared.fields), "Clear resets voxels and all presentation field mips")
	_check(_all_zero(cleared.air) and _all_zero(cleared.fx) and _all_zero(cleared.fx_instances), "Clear resets solver and FX history")
	_check(cleared.clock == 0 and _sim.tick == 0, "Clear resets clocks")
	_sim.load_scenario("Empty")
	var empty := await _snapshot()
	await _warm_fire()
	_sim.load_scenario("Empty")
	var reload := await _snapshot()
	_check(empty.voxels == reload.voxels and empty.fields == reload.fields, "preset reload returns identical authored geometry/fields")
	_check(_all_zero(reload.air) and _all_zero(reload.fx) and _all_zero(reload.fx_instances), "preset reload resets solver and FX history")
	_check(reload.clock == 0 and _sim.tick == 0, "preset reload resets clocks")

func _warm_fire() -> void:
	_sim.load_scenario("Forest fire")
	for i in 10:
		_sim.request_ticks(2)
		await RenderingServer.frame_post_draw

func _rt_seed_foam() -> void:
	_sim._rd.texture_clear(_sim._density_rid, Color(0, 0, 0, 128.0 / 255.0), 0, _sim.FIELDS_MIPS, 0, 1)
	_rt_refresh(1, 0.0)

func _rt_refresh(count: int, elapsed: float) -> void:
	for i in count:
		_sim._rt_presentation_seconds = elapsed
		_sim._rt_occupancy_update()
		_sim._rt_presentation_seconds = 0.0

func _snapshot() -> Dictionary:
	RenderingServer.call_on_render_thread(_rt_snapshot)
	return await snapshot_ready

func _rt_snapshot() -> void:
	var air := PackedByteArray()
	for texture in [_sim._air_vel[0], _sim._air_vel[1], _sim._air_pres[0], _sim._air_pres[1], _sim._air_div, _sim._air_occ, _sim._air_src]:
		air.append_array(_sim._rd.texture_get_data(texture, 0))
	var state := {
		"voxels": _sim._rd.texture_get_data(_sim._grid_rid, 0),
		"fields": _sim._rd.texture_get_data(_sim._density_rid, 0),
		"air": air,
		"fx": _sim._rd.buffer_get_data(_sim._fx_pool),
		"fx_instances": _sim._rd.buffer_get_data(_sim._layer_buffer[_sim.Layer.FX]),
		"spawns": _sim._rd.buffer_get_data(_sim._fx_spawns),
		"counters": _sim._rd.buffer_get_data(_sim._splat_counter),
		"clock": _sim._frame,
	}
	snapshot_ready.emit.call_deferred(state)

func _all_zero(bytes: PackedByteArray) -> bool:
	var zeros := PackedByteArray()
	zeros.resize(bytes.size())
	return not bytes.is_empty() and bytes == zeros

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if ok:
		print("ok: " + message)
	else:
		_failures += 1
		push_error(message)
