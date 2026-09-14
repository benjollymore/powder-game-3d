extends "res://scripts/discovery/interaction_lab.gd"
class SimStub extends Node3D:
	enum BrushMode { NORMAL, ONLY_AIR, ERASE }
	var records: Array = []
	var source: Dictionary = {}
	var finished := 0
	var cancelled := 0
	func world_size() -> float:
		return 1.0
	func record_stroke(id, centers, brush_radius, material, mode, seed) -> void:
		records.append([id, centers.duplicate(), brush_radius, material, mode, seed])
	func finish_edit_transaction(_id) -> void:
		pass
	func set_live_emitter(center, brush_radius, material, mode, rate, seed, surface) -> void:
		source = {"center": center, "radius": brush_radius, "material": material, "mode": mode, "rate": rate, "seed": seed, "surface": surface}
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
