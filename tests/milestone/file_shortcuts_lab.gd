extends "res://tests/milestone/editor_keyboard_lab.gd"
var pauses := 0
var steps := 0
func toggle_test_pause() -> void: pauses += 1
func step_test() -> void: steps += 1
