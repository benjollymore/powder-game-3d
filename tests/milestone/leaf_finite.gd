extends SceneTree
## Exhaustive six-face exposure masks; leaves must have finite instance records.
signal snapshot_ready(state: Dictionary)
var _sim: Node3D
var _checks := 0
var _failures := 0
var _probe := false
var _legacy_probe := false
var _centers: Array[Vector3i] = []
const DIRECTIONS := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	_legacy_probe = OS.get_cmdline_user_args().has("legacy_probe=1")
	_probe = _legacy_probe or OS.get_cmdline_user_args().has("probe=1")
	create_timer(90.0).timeout.connect(func(): push_error("Leaf regression timed out"); quit(1))
	call_deferred("_run")

func _run() -> void:
	_sim = load("res://scenes/sim_volume.tscn").instantiate()
	_sim.listen_to_time_controller = false
	root.add_child(_sim)
	for i in 4:
		await process_frame
	if _legacy_probe:
		RenderingServer.call_on_render_thread(_rt_legacy_kernel)
	var world := _fixture()
	_sim.upload(world.to_byte_array())
	var first := await _snapshot()
	_check(first.count == 63, "every exposed mask emits one leaf; fully buried mask emits none")
	_check(first.voxels == world.to_byte_array(), "leaf reconstruction preserves exact authoritative voxel bytes")
	var symmetric := 0
	var invalid := 0
	var zero_offsets := 0
	for seed in first.records:
		var bytes: PackedByteArray = first.records[seed]
		var values := bytes.to_float32_array()
		var finite := true
		for value in values:
			finite = finite and is_finite(value)
		var outward := Vector3i.ZERO
		for face in 6:
			if (seed & (1 << face)) != 0:
				outward += DIRECTIONS[face]
		var origin := Vector3(values[3], values[7], values[11])
		var offset := (origin + Vector3.ONE * 0.5) * VoxelCodec.GRID - Vector3(_centers[seed]) - Vector3.ONE * 0.5
		if not finite:
			invalid += 1
		if finite and offset.length() < 0.001:
			zero_offsets += 1
		if outward == Vector3i.ZERO:
			symmetric += 1
			print("SYMMETRIC mask=%d finite=%s origin=%s offset=%s" % [seed, finite, origin, offset])
		if not _probe:
			_check(finite, "mask=%d entire instance record is finite" % seed)
			_check(finite and absf(offset.length() - 0.45) < 0.0001, "mask=%d leaf origin has the intended 0.45-cell offset" % seed)
			if outward == Vector3i.ZERO and finite:
				var open_direction := false
				for face in 6:
					if (seed & (1 << face)) != 0 and offset.normalized().distance_to(Vector3(DIRECTIONS[face])) < 0.0001:
						open_direction = true
				_check(open_direction, "symmetric mask=%d fallback points through an exposed face" % seed)
	_check(symmetric == 7, "fixture covers all seven nonempty symmetric exposure masks")
	print("LEAF_PROBE symmetric=%d nonfinite=%d zero_offsets=%d" % [symmetric, invalid, zero_offsets])
	if not _probe:
		RenderingServer.call_on_render_thread(_sim._rt_occupancy_update)
		var second := await _snapshot()
		_check(first.records == second.records, "zero-time refresh reproduces exact per-seed instance bytes")
		_check(first.voxels == second.voxels and first.air == second.air, "leaf refresh preserves all voxel and air state")
		# Compile a control that changes only the origin expression back to its
		# old undefined normalization. Compare on this GPU, not frozen GPU bytes.
		RenderingServer.call_on_render_thread(_rt_legacy_kernel)
		_sim.upload(world.to_byte_array())
		var legacy := await _snapshot()
		_check(legacy.count == first.count, "fallback preserves physical leaf count")
		_check(legacy.voxels == first.voxels and legacy.air == first.air, "fallback preserves exact voxels and all seven air textures")
		for seed in first.records:
			var outward := Vector3i.ZERO
			for face in 6:
				if (seed & (1 << face)) != 0:
					outward += DIRECTIONS[face]
			if outward != Vector3i.ZERO:
				_check(first.records[seed] == legacy.records[seed], "mask=%d nonzero outward record is byte-identical to legacy control" % seed)
			else:
				var stable := true
				for field in 16:
					if field not in [3, 7, 11]:
						stable = stable and first.records[seed].slice(field * 4, field * 4 + 4) == legacy.records[seed].slice(field * 4, field * 4 + 4)
				_check(stable, "symmetric mask=%d preserves basis and custom-data bytes" % seed)
	print("LEAF_FINITE grid=%d checks=%d failures=%d probe=%s" % [VoxelCodec.GRID, _checks, _failures, _probe])
	_sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _fixture() -> PackedInt32Array:
	assert(VoxelCodec.GRID >= 96, "Leaf fixture needs grid=128 or larger")
	var world := WorldBuilder.empty()
	for mask in 64:
		var center := Vector3i(16 + (mask % 4) * 24, 16 + ((mask / 4) % 4) * 24, 16 + (mask / 16) * 24)
		_centers.append(center)
		world[VoxelCodec.index(center.x, center.y, center.z)] = VoxelCodec.encode(Elements.Id.PLANT, mask)
		for face in 6:
			if (mask & (1 << face)) == 0:
				var neighbor: Vector3i = center + DIRECTIONS[face]
				world[VoxelCodec.index(neighbor.x, neighbor.y, neighbor.z)] = VoxelCodec.encode(Elements.Id.WALL, 1)
	return world

func _snapshot() -> Dictionary:
	RenderingServer.call_on_render_thread(_rt_snapshot)
	return await snapshot_ready

func _rt_snapshot() -> void:
	_sim._rt_flush_render_preparation()
	var rd: RenderingDevice = _sim._rd
	var count := rd.buffer_get_data(_sim._splat_counter).decode_u32(4)
	var bytes := rd.buffer_get_data(_sim._layer_buffer[1], 0, count * 64)
	var records := {}
	for i in count:
		var record := bytes.slice(i * 64, (i + 1) * 64)
		var seed := roundi(record.decode_float(13 * 4) * 255.0)
		records[seed] = record
	var air := PackedByteArray()
	for texture in [_sim._air_vel[0], _sim._air_vel[1], _sim._air_pres[0], _sim._air_pres[1], _sim._air_div, _sim._air_occ, _sim._air_src]:
		air.append_array(rd.texture_get_data(texture, 0))
	snapshot_ready.emit.call_deferred({"records": records, "count": count, "voxels": rd.texture_get_data(_sim._grid_rid, 0), "air": air})

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if ok:
		print("ok: " + message)
	else:
		_failures += 1
		push_error(message)

func _rt_legacy_kernel() -> void:
	var rd: RenderingDevice = _sim._rd
	var source := FileAccess.get_file_as_string("res://shaders/compute/splat_emit.glsl").replace("#[compute]", "")
	assert(source.contains("leaf_offset_direction(outward, open_faces, h)"))
	source = source.replace("leaf_offset_direction(outward, open_faces, h)", "normalize(outward)")
	var shader_source := RDShaderSource.new()
	shader_source.source_compute = source
	var spirv := rd.shader_compile_spirv_from_source(shader_source)
	assert(spirv.compile_error_compute.is_empty(), spirv.compile_error_compute)
	for rid in [_sim._splat_set, _sim._splat_pipeline, _sim._splat_shader]:
		rd.free_rid(rid)
	_sim._splat_shader = rd.shader_create_from_spirv(spirv)
	_sim._splat_pipeline = rd.compute_pipeline_create(_sim._splat_shader, _sim._spec([VoxelCodec.GRID]))
	_sim._splat_set = rd.uniform_set_create([
		_sim._image_uniform(0), _sim._image_uniform(1, _sim._occ_rid), _sim._buffer_uniform(2, _sim._elements_buffer),
		_sim._buffer_uniform(3, _sim._splat_counter), _sim._buffer_uniform(4, _sim._layer_buffer[0]),
		_sim._buffer_uniform(5, _sim._layer_buffer[1]), _sim._buffer_uniform(6, _sim._layer_buffer[2]),
		_sim._buffer_uniform(7, _sim._fx_spawns)], _sim._splat_shader, 0)
