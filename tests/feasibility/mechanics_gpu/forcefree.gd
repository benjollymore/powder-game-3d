extends "res://tests/feasibility/momentum_gpu/run.gd"
func _initialize() -> void:
	_gpu_path="res://tools/feasibility/mechanics_gpu/gpu.gd"
	_results_path="res://docs/milestone/evidence-mechanics-gpu/forcefree-results.json"
	super._initialize()
