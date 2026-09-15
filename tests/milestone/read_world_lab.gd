extends "res://scripts/discovery/interaction_lab.gd"
## The real editor over a stub simulator whose paired state readback can be
## switched off to model a simulator without it.
class StateStub extends Node3D:
	signal state_ready(voxels: PackedByteArray, thermal: PackedByteArray)
	enum BrushMode { REPLACE, ONLY_AIR, ERASE, BOX, BOX_ONLY_AIR, HEAT, COOL }
	var world := PackedByteArray([1, 1, 1, 1])
	var thermal := PackedByteArray([1, 0, 0, 0, 0, 0, 0, 0])
	var edit_epoch := 0
	var edit_revision := 0
	var thermal_strokes: Array = []
	var live_thermal: Array = []
	func world_size() -> float:
		return 1.0
	func record_thermal_stroke(id: int, centers: Array[Vector3i], radius: int, kelvin: float) -> void:
		thermal_strokes.append([id, centers.duplicate(), radius, kelvin])
	func paint_thermal_stroke(centers: Array[Vector3i], radius: int, kelvin: float) -> void:
		live_thermal.append([centers.duplicate(), radius, kelvin])
	var surface_thermal: Array = []
	var live_surface_thermal: Array = []
	func record_surface_thermal_stroke(id: int, rays: Array, radius: int, kelvin: float) -> void:
		surface_thermal.append([id, rays.size(), radius, kelvin])
	func paint_surface_thermal_stroke(rays: Array, radius: int, kelvin: float) -> void:
		live_surface_thermal.append([rays.duplicate(true), radius, kelvin])
	func request_readback(callback: Callable) -> void:
		callback.call_deferred(world.duplicate())
	func request_state_readback() -> void:
		state_ready.emit.call_deferred(world.duplicate(), thermal.duplicate())
	func record_stroke(_id, _centers, _r, _m, _mode, _seed, _shape = 0, _axis = 1) -> void:
		pass
	func finish_edit_transaction(_id) -> void:
		pass
	func set_live_emitter(_c, _r, _m, _mode, _rate, _seed, _surface, _shape = 0, _axis = 1) -> void:
		pass
	func clear_live_emitter() -> void:
		pass
	func finish_live_emitter() -> void:
		pass
	func upload(_bytes: PackedByteArray, _thermal: PackedByteArray = PackedByteArray()) -> void:
		pass
## A simulator without the paired state readback: voxels only.
class PlainStub extends Node3D:
	enum BrushMode { NORMAL, ONLY_AIR, ERASE }
	var edit_epoch := 0
	var edit_revision := 0
	func world_size() -> float:
		return 1.0
	func request_readback(callback: Callable) -> void:
		callback.call_deferred(PackedByteArray([1, 1, 1, 1]))
func _ready() -> void:
	depth = 64
	sim = StateStub.new()
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
