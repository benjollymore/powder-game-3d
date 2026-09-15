extends RefCounted
## Render-thread-only regional undo resources. No whole-world texture readback.
## A transaction captures each touched 8³ tile once, before its first mutation.
const TILE := 8
## Bytes retained per captured cell: four packed voxel bytes plus the eight
## thermal bytes (temperature, latent progress). See region_copy.glsl.
const BYTES_PER_CELL := 12
## Same cell budget as the original 16 MiB voxel-only limit, now that every
## cell record also carries its thermal bytes.
const MAX_TRANSACTION_BYTES := 48 * 1024 * 1024
const COPY_PATH := "res://shaders/compute/editor/region_copy.glsl"
var rd: RenderingDevice
var grid: RID
var thermal: RID
var elements: RID
var size: int
var shader := RID()
var pipeline := RID()
var transactions := {}
var pending_buffers := {}
var disposed := false
var compile_shader: Callable
var pick_shader := RID()
var pick_pipeline := RID()
var stamp_shader := RID()
var stamp_pipeline := RID()
var surface_buffer := RID()
var surface_rays := RID()
var surface_pick_set := RID()
var surface_stamp_set := RID()
var preview_shader := RID()
var preview_pipeline := RID()
## Preview masks cover at most this brush radius (25^3 cells at radius 12).
const MAX_PREVIEW_RADIUS := 12
## Batch picks resolve at most this many rays in one dispatch (one 64-byte
## ray record and one 64-byte result record each).
const MAX_BATCH_RAYS := 32

func _init(device: RenderingDevice, texture: RID, thermal_texture: RID, elements_buffer: RID, grid_size: int, compile: Callable) -> void:
	rd = device
	grid = texture
	thermal = thermal_texture
	elements = elements_buffer
	size = grid_size
	compile_shader = compile
	shader = rd.shader_create_from_spirv(compile.call(COPY_PATH, false))
	pipeline = rd.compute_pipeline_create(shader)

func ensure_surface() -> void:
	if pick_pipeline.is_valid():
		return
	pick_shader = rd.shader_create_from_spirv(compile_shader.call("res://shaders/compute/editor/surface_pick.glsl", false))
	pick_pipeline = rd.compute_pipeline_create(pick_shader)
	stamp_shader = rd.shader_create_from_spirv(compile_shader.call("res://shaders/compute/editor/surface_stamp.glsl", false))
	stamp_pipeline = rd.compute_pipeline_create(stamp_shader)
	surface_buffer = rd.storage_buffer_create(64)
	# The single-ray path carries its ray in the push constant; the kernel still
	# binds a ray buffer, so keep one 64-byte placeholder for that set.
	surface_rays = rd.storage_buffer_create(64)
	surface_pick_set = _uniforms(surface_buffer, pick_shader, true, false, surface_rays)
	surface_stamp_set = _uniforms(surface_buffer, stamp_shader, true, true)

func ensure_preview() -> void:
	if preview_pipeline.is_valid():
		return
	preview_shader = rd.shader_create_from_spirv(compile_shader.call("res://shaders/compute/editor/preview_stamp.glsl", false))
	preview_pipeline = rd.compute_pipeline_create(preview_shader)

## Ghost preview (placement-brief contract 6): the exact cells one stamp of
## the given shape and mode would change at `center`, resolved on the GPU and
## downloaded asynchronously as a one-uint-per-cell mask. `callback` receives
## an Array[Vector3i] plus `metadata` fields on the main thread.
func request_preview(center: Vector3i, radius: int, mode: int, shape: int, axis: int, metadata: Dictionary, callback: Callable) -> void:
	ensure_preview()
	radius = clampi(radius, 0, MAX_PREVIEW_RADIUS)
	var side := 2 * radius + 1
	var results := rd.storage_buffer_create(4 * side * side * side)
	var uniforms := _uniforms(results, preview_shader, false, false)
	pending_buffers[results] = [uniforms]
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, preview_pipeline)
	rd.compute_list_bind_uniform_set(cl, uniforms, 0)
	var push := PackedInt32Array([center.x, center.y, center.z, radius, mode, shape, axis, size]).to_byte_array()
	rd.compute_list_set_push_constant(cl, push, push.size())
	var groups := ceili(side / 8.0)
	rd.compute_list_dispatch(cl, groups, groups, groups)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	var err := rd.buffer_get_data_async(results, _received_preview.bind(results, center, radius, metadata, callback))
	if err != OK:
		_finish_preview(rd.buffer_get_data(results), results, center, radius, metadata, callback)

func _received_preview(bytes: PackedByteArray, buffer: RID, center: Vector3i, radius: int, metadata: Dictionary, callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_finish_preview.bind(bytes, buffer, center, radius, metadata, callback))

func _finish_preview(bytes: PackedByteArray, buffer: RID, center: Vector3i, radius: int, metadata: Dictionary, callback: Callable) -> void:
	if disposed:
		return
	_free_pending(buffer)
	callback.call_deferred(decode_preview(bytes, center, radius), metadata)

static func decode_preview(bytes: PackedByteArray, center: Vector3i, radius: int) -> Array[Vector3i]:
	var cells: Array[Vector3i] = []
	var side := 2 * radius + 1
	if bytes.size() != 4 * side * side * side:
		return cells
	for i in side * side * side:
		if bytes.decode_u32(i * 4) != 0:
			cells.append(center + Vector3i(i % side, (i / side) % side, i / (side * side)) - Vector3i.ONE * radius)
	return cells

## Single-ray preview pick: a wrapper over the batch path; `callback`
## receives one decoded record merged with `metadata`.
func request_pick(ray: Dictionary, radius: int, erase: bool, metadata: Dictionary, callback: Callable) -> void:
	request_picks([ray], radius, erase, metadata, _deliver_single_pick.bind(callback))

func _deliver_single_pick(results: Array, callback: Callable) -> void:
	callback.call(results[0])

## Batch pick: up to MAX_BATCH_RAYS rays resolve in one dispatch and one
## asynchronous 64-byte-per-ray download. `callback` receives an Array of
## decoded records in ray order, each merged with `metadata` plus its `index`.
func request_picks(rays: Array, radius: int, erase: bool, metadata: Dictionary, callback: Callable) -> void:
	ensure_surface()
	var count := mini(rays.size(), MAX_BATCH_RAYS)
	var results := rd.storage_buffer_create(64 * count)
	var records := PackedByteArray()
	for i in count:
		records.append_array(_encode_ray(rays[i], radius, erase, 0))
	var ray_buffer := rd.storage_buffer_create(records.size(), records)
	var uniforms := _uniforms(results, pick_shader, true, false, ray_buffer)
	pending_buffers[results] = [uniforms, ray_buffer]
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pick_pipeline)
	rd.compute_list_bind_uniform_set(cl, uniforms, 0)
	var push := _encode_ray(rays[0], radius, erase, count)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, count, 1, 1)
	rd.compute_list_add_barrier(cl)
	rd.compute_list_end()
	var err := rd.buffer_get_data_async(results, _received_picks.bind(results, count, metadata, callback))
	if err != OK:
		_finish_picks(rd.buffer_get_data(results), results, count, metadata, callback)

func _received_picks(bytes: PackedByteArray, buffer: RID, count: int, metadata: Dictionary, callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_finish_picks.bind(bytes, buffer, count, metadata, callback))

func _finish_picks(bytes: PackedByteArray, buffer: RID, count: int, metadata: Dictionary, callback: Callable) -> void:
	if disposed:
		return
	_free_pending(buffer)
	var results: Array = []
	for i in count:
		var result := decode_pick(bytes.slice(i * 64, (i + 1) * 64))
		result.merge(metadata)
		result.index = i
		results.append(result)
	callback.call_deferred(results)

func _free_pending(buffer: RID) -> void:
	if pending_buffers.has(buffer):
		for rid in pending_buffers[buffer]:
			rd.free_rid(rid)
		rd.free_rid(buffer)
		pending_buffers.erase(buffer)

func pick_sync(ray: Dictionary, radius: int, erase: bool) -> Dictionary:
	ensure_surface()
	var cl := rd.compute_list_begin()
	_dispatch_pick(cl, ray, radius, erase, surface_pick_set)
	rd.compute_list_end()
	# Build surface commands need the actual tile coordinates before recording
	# undo. This fence downloads 64 bytes, never the voxel texture.
	return decode_pick(rd.buffer_get_data(surface_buffer))

## Synchronous batch pick for Build strokes: every ray in `rays` is resolved
## against the current GPU state in one dispatch per MAX_BATCH_RAYS and one
## 64-byte-per-ray fence, results in ray order. Never downloads the voxel texture.
func pick_sync_batch(rays: Array, radius: int, erase: bool) -> Array:
	ensure_surface()
	var results: Array = []
	var start := 0
	while start < rays.size():
		var count := mini(rays.size() - start, MAX_BATCH_RAYS)
		var records := PackedByteArray()
		for i in count:
			records.append_array(_encode_ray(rays[start + i], radius, erase, 0))
		var out := rd.storage_buffer_create(64 * count)
		var ray_buffer := rd.storage_buffer_create(records.size(), records)
		var uniforms := _uniforms(out, pick_shader, true, false, ray_buffer)
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pick_pipeline)
		rd.compute_list_bind_uniform_set(cl, uniforms, 0)
		var push := _encode_ray(rays[start], radius, erase, count)
		rd.compute_list_set_push_constant(cl, push, push.size())
		rd.compute_list_dispatch(cl, count, 1, 1)
		rd.compute_list_add_barrier(cl)
		rd.compute_list_end()
		var bytes := rd.buffer_get_data(out)
		for i in count:
			results.append(decode_pick(bytes.slice(i * 64, (i + 1) * 64)))
		rd.free_rid(uniforms)
		rd.free_rid(ray_buffer)
		rd.free_rid(out)
		start += count
	return results

## Bytes 52..63 of the pick record carry the hit cell's probe payload:
## temperature (float bits), liquid amount and flag byte. See surface_pick.glsl.
static func decode_pick(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() != 64:
		return {"valid": false, "hit": Vector3i(-1, -1, -1), "normal": Vector3i.ZERO, "target": Vector3i(-1, -1, -1), "element": 0, "visited": 0,
			"temperature": 0.0, "amount": 0, "flags": 0}
	return {"valid": bytes.decode_s32(44) != 0, "hit": Vector3i(bytes.decode_s32(0), bytes.decode_s32(4), bytes.decode_s32(8)),
		"normal": Vector3i(bytes.decode_s32(16), bytes.decode_s32(20), bytes.decode_s32(24)),
		"target": Vector3i(bytes.decode_s32(32), bytes.decode_s32(36), bytes.decode_s32(40)),
		"element": bytes.decode_s32(12), "visited": bytes.decode_s32(48),
		"temperature": bytes.decode_float(52), "amount": bytes.decode_s32(56), "flags": bytes.decode_s32(60)}

## 64-byte ray record shared by the push constant (single ray, batch = 0)
## and the batch ray buffer. See surface_pick.glsl.
func _encode_ray(ray: Dictionary, radius: int, erase: bool, batch: int) -> PackedByteArray:
	var origin: Vector3 = ray.origin
	var direction: Vector3 = ray.direction
	var record := PackedFloat32Array([origin.x, origin.y, origin.z, 0.0, direction.x, direction.y, direction.z, 0.0]).to_byte_array()
	record.append_array(PackedInt32Array([size, radius, int(erase), ray.mask, int(ray.section), ray.axis, ray.depth, batch]).to_byte_array())
	return record

func _dispatch_pick(cl: int, ray: Dictionary, radius: int, erase: bool, uniforms: RID) -> void:
	var push := _encode_ray(ray, radius, erase, 0)
	rd.compute_list_bind_compute_pipeline(cl, pick_pipeline)
	rd.compute_list_bind_uniform_set(cl, uniforms, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, 1, 1, 1)
	rd.compute_list_add_barrier(cl)

func stamp_surface(cl: int, ray: Dictionary, radius: int, element: int, mode: int, seed: int, amount: int, shape: int = 0) -> void:
	ensure_surface()
	_dispatch_pick(cl, ray, radius, mode == 2, surface_pick_set)
	rd.compute_list_bind_compute_pipeline(cl, stamp_pipeline)
	rd.compute_list_bind_uniform_set(cl, surface_stamp_set, 0)
	# material.z carries the brush shape (0 sphere, 1 cube, 2 disc on the picked face).
	var push := PackedInt32Array([size, radius, element, mode, seed, amount, shape, 0]).to_byte_array()
	rd.compute_list_set_push_constant(cl, push, push.size())
	var groups := ceili(float(2 * radius + 1) / 8.0)
	rd.compute_list_dispatch(cl, groups, groups, groups)
	rd.compute_list_add_barrier(cl)

func begin(id: int, epoch: int, callback: Callable) -> void:
	transactions[id] = {"id": id, "epoch": epoch, "callback": callback, "seen": {},
		"regions": [], "bytes": 0, "pending": 0, "closed": false, "error": "", "valid": true}

func capture_stroke(id: int, centers: Array[Vector3i], radius: int) -> bool:
	if not transactions.has(id):
		return false
	var tx: Dictionary = transactions[id]
	var added := {}
	var bounds: Array = []
	for center in centers:
		var lo := (center - Vector3i.ONE * radius).clamp(Vector3i.ZERO, Vector3i.ONE * size)
		var hi := (center + Vector3i.ONE * (radius + 1)).clamp(Vector3i.ZERO, Vector3i.ONE * size)
		if lo.x >= hi.x or lo.y >= hi.y or lo.z >= hi.z:
			continue
		for z in range(lo.z / TILE, (hi.z - 1) / TILE + 1):
			for y in range(lo.y / TILE, (hi.y - 1) / TILE + 1):
				for x in range(lo.x / TILE, (hi.x - 1) / TILE + 1):
					var tile := Vector3i(x, y, z)
					if not tx.seen.has(tile) and not added.has(tile):
						added[tile] = true
						bounds.append({"lo": tile * TILE, "hi": (tile * TILE + Vector3i.ONE * TILE).min(Vector3i.ONE * size)})
	if not _capture(id, bounds):
		return false
	tx.seen.merge(added)
	return true

func capture_region(id: int, lo: Vector3i, hi: Vector3i) -> bool:
	# Same first-touch tile policy as brushes; overlapping region/brush commands
	# within one transaction must retain the original before-image exactly once.
	if not transactions.has(id):
		return false
	var tx: Dictionary = transactions[id]
	var bounds: Array = []
	var added := {}
	for z in range(lo.z / TILE, (hi.z - 1) / TILE + 1):
		for y in range(lo.y / TILE, (hi.y - 1) / TILE + 1):
			for x in range(lo.x / TILE, (hi.x - 1) / TILE + 1):
				var tile := Vector3i(x, y, z)
				if not tx.seen.has(tile):
					added[tile] = true
					bounds.append({"lo": tile * TILE, "hi": (tile * TILE + Vector3i.ONE * TILE).min(Vector3i.ONE * size)})
	if not _capture(id, bounds):
		return false
	tx.seen.merge(added)
	return true

func capture_existing_regions(id: int, regions: Array) -> bool:
	# History records contain unique aligned tiles, validated before submission.
	# Batch the inverse into one transfer instead of one buffer per tile.
	var bounds: Array = []
	for region in regions:
		bounds.append({"lo": region.lo, "hi": region.hi})
	return _capture(id, bounds)


func _capture(id: int, bounds: Array) -> bool:
	if not transactions.has(id):
		return false
	var tx: Dictionary = transactions[id]
	if tx.closed or tx.error != "":
		return false
	var byte_count := 0
	for region in bounds:
		var extent: Vector3i = region.hi - region.lo
		region["offset"] = byte_count
		region["length"] = extent.x * extent.y * extent.z * BYTES_PER_CELL
		byte_count += region.length
	if tx.bytes + byte_count > MAX_TRANSACTION_BYTES:
		tx.error = "Undo limit reached; remaining paint was skipped. Use a smaller stroke or region."
		return false
	if byte_count == 0:
		return true
	var buffer := rd.storage_buffer_create(byte_count)
	var uniforms := _uniforms(buffer)
	pending_buffers[buffer] = uniforms
	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniforms, 0)
	for region in bounds:
		_dispatch(cl, region.lo, region.hi, region.offset / 4, false)
	rd.compute_list_end()
	tx.bytes += byte_count
	tx.pending += 1
	# Mutations may now be queued: this buffer already captures their before-image.
	var err := rd.buffer_get_data_async(buffer, _received.bind(id, buffer, bounds))
	if err != OK:
		# Explicit failure fallback is regional, never a full texture download.
		_finish_capture(rd.buffer_get_data(buffer), id, buffer, bounds)
	return true

func _received(bytes: PackedByteArray, id: int, buffer: RID, bounds: Array) -> void:
	RenderingServer.call_on_render_thread(_finish_capture.bind(bytes, id, buffer, bounds))

func _finish_capture(bytes: PackedByteArray, id: int, buffer: RID, bounds: Array) -> void:
	if disposed:
		return
	if pending_buffers.has(buffer):
		rd.free_rid(pending_buffers[buffer])
		rd.free_rid(buffer)
		pending_buffers.erase(buffer)
	if not transactions.has(id):
		return
	var tx: Dictionary = transactions[id]
	var expected := 0
	for region in bounds:
		expected += region.length
	if bytes.size() != expected:
		tx.valid = false
		tx.error = "Undo readback failed; this edit cannot be undone. Build history was cleared."
		tx.pending -= 1
		_complete(id)
		return
	for region in bounds:
		tx.regions.append({"lo": region.lo, "hi": region.hi,
			"bytes": bytes.slice(region.offset, region.offset + region.length)})
	tx.pending -= 1
	_complete(id)

func finish(id: int) -> void:
	if transactions.has(id):
		transactions[id].closed = true
		_complete(id)

func _complete(id: int) -> void:
	var tx: Dictionary = transactions[id]
	if not tx.closed or tx.pending > 0:
		return
	var callback: Callable = tx.callback
	transactions.erase(id)
	callback.call_deferred({"id": id, "epoch": tx.epoch, "regions": tx.regions if tx.valid else [],
		"bytes": tx.bytes, "error": tx.error, "valid": tx.valid})

func restore(regions: Array) -> void:
	for region in regions:
		var bytes: PackedByteArray = region.bytes
		var buffer := rd.storage_buffer_create(bytes.size(), bytes)
		var uniforms := _uniforms(buffer)
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl, pipeline)
		rd.compute_list_bind_uniform_set(cl, uniforms, 0)
		_dispatch(cl, region.lo, region.hi, 0, true)
		rd.compute_list_end()
		rd.free_rid(uniforms)
		rd.free_rid(buffer)

func _uniforms(buffer: RID, for_shader: RID = RID(), with_thermal := true, with_elements := false, rays := RID()) -> RID:
	var image := RDUniform.new()
	image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image.binding = 0
	image.add_id(grid)
	var data := RDUniform.new()
	data.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	data.binding = 1
	data.add_id(buffer)
	var uniforms: Array[RDUniform] = [image, data]
	if with_thermal:
		# Region copy, pick and stamp all read or write the thermal layer; the
		# stamp also needs element initial temperatures.
		var heat := RDUniform.new()
		heat.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		heat.binding = 2
		heat.add_id(thermal)
		uniforms.append(heat)
	if rays.is_valid():
		# The pick kernel reads batch rays at binding 3.
		var batch := RDUniform.new()
		batch.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		batch.binding = 3
		batch.add_id(rays)
		uniforms.append(batch)
	if with_elements:
		var elems := RDUniform.new()
		elems.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		elems.binding = 3
		elems.add_id(elements)
		uniforms.append(elems)
	return rd.uniform_set_create(uniforms, for_shader if for_shader.is_valid() else shader, 0)

func _dispatch(cl: int, lo: Vector3i, hi: Vector3i, offset: int, restore_mode: bool) -> void:
	var extent := hi - lo
	var push := PackedInt32Array([lo.x, lo.y, lo.z, int(restore_mode), extent.x, extent.y, extent.z, offset]).to_byte_array()
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, ceili(extent.x / 8.0), ceili(extent.y / 8.0), ceili(extent.z / 8.0))
	rd.compute_list_add_barrier(cl)

func free_resources() -> void:
	disposed = true
	if not pending_buffers.is_empty():
		# Deliver and clear every queued asynchronous download now, while the
		# scripts that own their callables are still alive. Otherwise the device
		# releases them during display teardown, after script finalisation.
		rd.buffer_get_data(pending_buffers.keys()[0], 0, 4)
	for buffer in pending_buffers.keys():
		_free_pending(buffer)
	pending_buffers.clear()
	transactions.clear()
	for rid in [surface_pick_set, surface_stamp_set, surface_buffer, surface_rays, pick_pipeline, pick_shader, stamp_pipeline, stamp_shader, preview_pipeline, preview_shader, pipeline, shader]:
		if rid.is_valid():
			rd.free_rid(rid)
