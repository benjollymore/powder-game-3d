extends "res://scripts/discovery/interaction_lab.gd"
## Loaded after autoload initialization by gesture_routing.gd.
class SimStub extends Node3D:
	func world_size() -> float:
		return 1.0

func _ready() -> void:
	depth = 64
	sim = SimStub.new()
	add_child(sim)
	camera = Camera3D.new()
	add_child(camera)
	_build_ui()
	_face_plane()
