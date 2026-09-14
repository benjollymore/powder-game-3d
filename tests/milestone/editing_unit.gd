extends SceneTree
const Emission := preload("res://scripts/discovery/brush_emission.gd")
const EditGPU := preload("res://scripts/sim/voxel_edit_gpu.gd")
var failures := 0
var checks := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
func _initialize() -> void:
	for fps in [15, 30, 60, 120, 240]:
		var emitter := Emission.new()
		var count := 0
		for frame in fps * 10:
			count += emitter.advance(1.0 / fps)
		check(count == 240, "10 second held stroke emits 240 stamps at %d FPS, got %d" % [fps, count])
	var emitter := Emission.new()
	check(emitter.advance(60.0) == 4, "one-minute stall emits at most four catch-up stamps")
	check(emitter.advance(0.0) == 0 and emitter.advance(-1.0) == 0, "invalid/zero time does not paint")
	check(emitter.advance(1.0 / 24.0) == 1, "stalls retain no unbounded catch-up backlog")
	emitter.advance(0.02)
	emitter.reset()
	check(emitter.advance(0.025) == 0, "new gesture cannot inherit fractional emission credit")
	check(not EditGPU.decode_pick(PackedByteArray()).valid, "truncated pick reply cannot advertise a valid target")
	var reply := PackedInt32Array([1, 2, 3, 4, 0, 0, 1, 1, 1, 2, 7, 1, 19, 0, 0, 0]).to_byte_array()
	var pick := EditGPU.decode_pick(reply)
	check(pick.valid and pick.hit == Vector3i(1, 2, 3) and pick.target == Vector3i(1, 2, 7) and pick.normal == Vector3i.BACK,
		"64-byte GPU pick layout decodes hit, offset target and outward normal")
	print("Editing CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
