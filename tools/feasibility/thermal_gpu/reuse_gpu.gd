extends "res://tools/feasibility/thermal_gpu/fused_gpu.gd"
## Same 12B/cell fused layout, but explicitly reuse center temperature/conductivity.
func _init() -> void:
	heat_kernel = "reuse_heat"
	audit_kernel = "reuse_audit"
