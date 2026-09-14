extends MultiMeshInstance3D
## Shadow-only stand-in for the voxel mass. The raymarched box cannot cast
## shadows cheaply (the shadow pass would re-run the raymarch over the whole
## shadow atlas), so this keeps one cube per occupied 8^3 brick, refreshed
## from an async readback of the sim's occupancy texture every few frames.

@export var sim_path: NodePath = ^".."
@export var refresh_every_frames := 6

var _sim: Node3D
var _frame := 0
var _last: PackedByteArray
var _pending := false


func _ready() -> void:
	_sim = get_node(sim_path)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var n: int = _sim.OCCUPANCY_GRID
	mm.instance_count = n * n * n
	var box := BoxMesh.new()
	box.size = Vector3.ONE / n
	mm.mesh = box
	multimesh = mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	var zero := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i in mm.instance_count:
		mm.set_instance_transform(i, zero)
	_sim.occupancy_ready.connect(_on_occupancy)


func _process(_delta: float) -> void:
	_frame += 1
	if _pending or _frame % refresh_every_frames != 0:
		return
	_pending = true
	_sim.request_occupancy_readback()


func _on_occupancy(bytes: PackedByteArray) -> void:
	_pending = false
	if bytes == _last:
		return
	_last = bytes
	var n: int = _sim.OCCUPANCY_GRID
	var size := 1.0 / n
	var zero := Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO)
	for i in bytes.size():
		if bytes[i] == 0:
			multimesh.set_instance_transform(i, zero)
		else:
			var x := i % n
			var y := (i / n) % n
			var z := i / (n * n)
			var center := (Vector3(x, y, z) + Vector3(0.5, 0.5, 0.5)) * size - Vector3(0.5, 0.5, 0.5)
			multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, center))
