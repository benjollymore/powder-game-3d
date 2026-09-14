extends "res://tests/milestone/paint_tools_lab.gd"
## Real tool controls and input routing; replace only the effects being counted.
var run_requests := 0
var reset_requests := 0
var undo_requests := 0
func run_or_restore() -> void:
	run_requests += 1
func reset_container() -> void:
	reset_requests += 1
func undo_edit() -> void:
	undo_requests += 1
