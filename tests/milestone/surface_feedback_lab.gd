extends "res://tests/milestone/paint_tools_lab.gd"
# Keep real edit/source termination and controls; GPU shader uniforms are
# covered by the default-scene acceptance harness instead.
func _update_plane() -> void:
	_invalidate_picks()
