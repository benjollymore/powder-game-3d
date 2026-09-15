extends "res://scripts/discovery/interaction_lab.gd"
## Editor over a stub simulator implementing the history-tile contract on CPU.
class KeepStub extends Node3D:
	const EditGPU := preload("res://scripts/sim/voxel_edit_gpu.gd")
	enum BrushMode { NORMAL, ONLY_AIR, ERASE }
	var world := PackedByteArray()
	var uploads: Array[PackedByteArray] = []
	var restored: Array = []
	var edit_epoch := 0
	var edit_revision := 0
	func world_size() -> float:
		return 1.0
	func record_stroke(_id, _centers, _r, _m, _mode, _seed) -> void:
		pass
	func finish_edit_transaction(_id) -> void:
		pass
	func set_live_emitter(_c, _r, _m, _mode, _rate, _seed, _surface) -> void:
		pass
	func clear_live_emitter() -> void:
		pass
	func finish_live_emitter() -> void:
		pass
	func request_readback(callback: Callable) -> void:
		callback.call_deferred(world.duplicate())
	func upload(bytes: PackedByteArray) -> void:
		uploads.append(bytes.duplicate())
		world = bytes.duplicate()
		edit_epoch += 1
		edit_revision += 1
	func tile_bytes(source: PackedByteArray, region: Dictionary) -> PackedByteArray:
		var out := PackedByteArray()
		for z in range(region.lo.z, region.hi.z):
			for y in range(region.lo.y, region.hi.y):
				var start := VoxelCodec.index(region.lo.x, y, z) * 4
				out.append_array(source.slice(start, start + (region.hi.x - region.lo.x) * 4))
		return out
	func capture_regions(bounds: Array, callback: Callable) -> int:
		var regions := []
		var total := 0
		for region in bounds:
			var bytes := tile_bytes(world, region)
			regions.append({"lo": region.lo, "hi": region.hi, "bytes": bytes})
			total += bytes.size()
		callback.call_deferred({"id": 1, "epoch": edit_epoch, "regions": regions, "bytes": total, "error": "", "valid": true})
		return 1
	func restore_edit_transaction(record: Dictionary) -> bool:
		if record.epoch != edit_epoch:
			return false
		restored.append(record)
		for region in record.regions:
			var offset := 0
			for z in range(region.lo.z, region.hi.z):
				for y in range(region.lo.y, region.hi.y):
					var width: int = (region.hi.x - region.lo.x) * 4
					var start := VoxelCodec.index(region.lo.x, y, z) * 4
					for i in width:
						world[start + i] = region.bytes[offset + i]
					offset += width
		edit_revision += 1
		return true
func _ready() -> void:
	depth = 64
	sim = KeepStub.new()
	add_child(sim)
	camera = Camera3D.new()
	add_child(camera)
	selection_mesh = MeshInstance3D.new()
	add_child(selection_mesh)
	marker = MeshInstance3D.new()
	add_child(marker)
	guide = MeshInstance3D.new()
	add_child(guide)
	_build_ui()
	_face_plane()
	_ready_to_edit = true
