extends RefCounted
## Render-thread-only regional undo resources. No whole-world texture readback.
## A transaction captures each touched 8³ tile once, before its first mutation.
const TILE := 8
const MAX_TRANSACTION_BYTES := 16 * 1024 * 1024
const COPY_PATH := "res://shaders/compute/editor/region_copy.glsl"
var rd: RenderingDevice
var grid: RID
var size: int
var shader := RID()
var pipeline := RID()
var transactions := {}
var pending_buffers := {}
var disposed := false

func _init(device: RenderingDevice, texture: RID, grid_size: int, compile: Callable) -> void:
	rd = device
	grid = texture
	size = grid_size
	shader = rd.shader_create_from_spirv(compile.call(COPY_PATH, false))
	pipeline = rd.compute_pipeline_create(shader)

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
		region["length"] = extent.x * extent.y * extent.z * 4
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

func _uniforms(buffer: RID) -> RID:
	var image := RDUniform.new()
	image.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image.binding = 0
	image.add_id(grid)
	var data := RDUniform.new()
	data.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	data.binding = 1
	data.add_id(buffer)
	return rd.uniform_set_create([image, data], shader, 0)

func _dispatch(cl: int, lo: Vector3i, hi: Vector3i, offset: int, restore_mode: bool) -> void:
	var extent := hi - lo
	var push := PackedInt32Array([lo.x, lo.y, lo.z, int(restore_mode), extent.x, extent.y, extent.z, offset]).to_byte_array()
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, ceili(extent.x / 8.0), ceili(extent.y / 8.0), ceili(extent.z / 8.0))
	rd.compute_list_add_barrier(cl)

func free_resources() -> void:
	disposed = true
	for buffer in pending_buffers:
		rd.free_rid(pending_buffers[buffer])
		rd.free_rid(buffer)
	pending_buffers.clear()
	transactions.clear()
	for rid in [pipeline, shader]:
		if rid.is_valid():
			rd.free_rid(rid)
