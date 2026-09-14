extends Node3D
## M0 stand-in for the simulation: rotates only when TimeController hands out
## ticks, so pause / step / slow-mo are visible before the real sim exists.

@export var turns_per_second := 0.25


func _ready() -> void:
	TimeController.ticks_requested.connect(_on_ticks)


func _on_ticks(count: int) -> void:
	if count == 0:
		return
	rotate_y(TAU * turns_per_second * count / TimeController.TICKS_PER_SECOND)
