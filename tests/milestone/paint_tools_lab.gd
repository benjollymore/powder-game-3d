extends "res://scripts/discovery/interaction_lab.gd"
class SimStub extends Node3D:
	enum BrushMode { NORMAL, ONLY_AIR, ERASE, BOX, BOX_ONLY_AIR, HEAT, COOL, BOX_ERASE } # mirrors VoxelSim.BrushMode values
	var records: Array = []
	var source: Dictionary = {}
	var finished := 0
	var cancelled := 0
	func world_size() -> float:
		return 1.0
	func record_stroke(id, centers, brush_radius, material, mode, seed, shape = 0, axis = 1) -> void:
		records.append([id, centers.duplicate(), brush_radius, material, mode, seed, shape, axis])
	var regions: Array = []
	var transactions := 0
	var edit_epoch := 0
	## Opens a transaction without completing it; tests clear `capturing`
	## themselves, as the paint tools suite does.
	func begin_edit_transaction(_callback) -> int:
		transactions += 1
		return transactions
	func set_param(_name, _value) -> void:
		pass
	var edit_revision := 0
	## Preview and pick requests are fire-and-forget here: the CPU suites drive
	## them to prove they do not disturb editor state, never to read cells back.
	func request_surface_pick(_ray, _radius, _erase, _callback) -> void:
		pass
	func request_stamp_preview(_center, _radius, _erase, _shape, _axis, _callback, _any_cell := false) -> void:
		pass
	func reverse_edit_transaction(_record, _callback) -> bool:
		return false
	func record_region(id, lo, hi, material, mode = 4) -> void:
		regions.append([id, lo, hi, material, mode])
	func finish_edit_transaction(_id) -> void:
		pass
	func set_live_emitter(center, brush_radius, material, mode, rate, seed, surface, shape = 0, axis = 1) -> void:
		source = {"center": center, "radius": brush_radius, "material": material, "mode": mode, "rate": rate, "seed": seed, "surface": surface, "shape": shape, "axis": axis}
	func clear_live_emitter() -> void:
		cancelled += 1
		source.clear()
	func finish_live_emitter() -> void:
		finished += 1
		source.clear()
func _ready() -> void:
	depth = 64
	sim = SimStub.new()
	add_child(sim)
	camera = Camera3D.new()
	add_child(camera)
	selection_mesh = MeshInstance3D.new()
	add_child(selection_mesh)
	_build_ui()
	_face_plane()
