extends "res://scripts/discovery/interaction_lab.gd"
## Real palette, speed and Examples controls over a stub simulator and guard.
class SimStub extends Node3D:
	enum BrushMode { NORMAL, ONLY_AIR, ERASE }
	var uploads: Array[PackedByteArray] = []
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
	func upload(bytes: PackedByteArray) -> void:
		uploads.append(bytes.duplicate())
		edit_epoch += 1
		edit_revision += 1
class GuardStub extends Node:
	var kinds: Array[String] = []
	var callbacks: Array[Callable] = []
	func request(kind: String, callback: Callable, _after_save: Callable = Callable()) -> void:
		kinds.append(kind)
		callbacks.append(callback)
func _ready() -> void:
	depth = 64
	sim = SimStub.new()
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
	document_guard = GuardStub.new()
	add_child(document_guard)
	_ready_to_edit = true
