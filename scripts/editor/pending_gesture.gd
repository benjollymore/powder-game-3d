extends RefCounted
## One bounded authored gesture waiting for a prior history capture. Coordinates
## or rays are sampled at input time; replay never projects an old screen point.
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
const MAX_SAMPLES := 256
var metadata: Dictionary
var samples: Array[Dictionary] = []
var closed := false
var limited := false
var warning := ""
var connect_next := false
var _last_key: Variant

func _init(value: Dictionary) -> void:
	metadata = value.duplicate(true)

func add_cell(cell: Vector3i) -> void:
	if cell.x < 0:
		break_segment()
		return
	_add({"cell": cell}, cell)

func add_ray(ray: Dictionary) -> void:
	_add(ray.duplicate(true), ray)

func _add(sample: Dictionary, key: Variant) -> void:
	if closed or (connect_next and key == _last_key):
		return
	if samples.size() >= MAX_SAMPLES:
		limited = true
		warning = "Pending stroke limit reached; only the recorded part was painted."
		closed = true
		return
	sample["connect"] = connect_next
	samples.append(sample)
	_last_key = key.duplicate(true) if key is Dictionary else key
	connect_next = true

func break_segment() -> void:
	connect_next = false

func centers() -> Array[Vector3i]:
	var result: Array[Vector3i] = []
	var previous := Vector3i(-1, -1, -1)
	for sample in samples:
		var cell: Vector3i = sample.cell
		if sample.connect and previous.x >= 0:
			var line := Geometry.stroke(previous, cell)
			line.remove_at(0)
			result.append_array(line)
		else:
			result.append(cell)
		previous = cell
	return result

func last_cell() -> Vector3i:
	return samples.back().cell if connect_next and not samples.is_empty() else Vector3i(-1, -1, -1)
