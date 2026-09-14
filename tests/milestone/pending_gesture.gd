extends SceneTree
const Pending := preload("res://scripts/editor/pending_gesture.gd")
var checks := 0
var failures := 0
func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1
func _initialize() -> void:
	var metadata := {"element": 2, "radius": 1, "erase": false, "view": {"section": true, "depth": 64}}
	var gesture := Pending.new(metadata)
	metadata.element = 3
	metadata.radius = 9
	metadata.view.depth = 32
	check(gesture.metadata.element == 2 and gesture.metadata.radius == 1 and gesture.metadata.view.depth == 64,
		"waiting gesture owns frozen material, radius and nested view metadata")
	gesture.add_cell(Vector3i.ZERO)
	gesture.add_cell(Vector3i(2, 0, 0))
	gesture.add_cell(Vector3i(2, 2, 0))
	var cells: Array[Vector3i] = gesture.centers()
	check(cells == [Vector3i.ZERO, Vector3i(1, 0, 0), Vector3i(2, 0, 0), Vector3i(2, 1, 0), Vector3i(2, 2, 0)],
		"waiting L-shaped stroke retains both legs rather than shortcutting its curve")
	gesture.break_segment()
	gesture.add_cell(Vector3i(4, 4, 0))
	check(Vector3i(3, 3, 0) not in gesture.centers(), "toolbar break cannot create a connector during later replay")
	var before: Array[Vector3i] = gesture.centers()
	gesture.closed = true
	gesture.add_cell(Vector3i(5, 5, 0))
	check(gesture.centers() == before, "release seals the recorded path before history becomes available")
	gesture = Pending.new(metadata)
	var ray := {"origin": Vector3(0, 0, 1), "direction": Vector3.FORWARD, "section": true, "axis": 2, "depth": 64}
	gesture.add_ray(ray)
	ray.origin.x = 0.2
	gesture.add_ray(ray)
	ray.origin.x = 0.5
	gesture.break_segment()
	gesture.add_ray(ray)
	ray.depth = 12
	check(gesture.samples[0].origin == Vector3(0, 0, 1) and gesture.samples[0].depth == 64 and gesture.samples[1].connect and not gesture.samples[2].connect,
		"surface rays are owned snapshots with explicit segment continuity")
	gesture = Pending.new(metadata)
	for i in 10000:
		gesture.add_cell(Vector3i(i % 256, i / 256, 0))
	check(gesture.limited and gesture.closed and gesture.samples.size() == 256 and gesture.samples.back().cell == Vector3i(255, 0, 0),
		"long stalls retain a bounded 256-sample prefix, seal it and report the limit")
	var duplicate := Pending.new(metadata)
	for i in 10000:
		duplicate.add_cell(Vector3i.ONE)
	check(duplicate.samples.size() == 1 and not duplicate.limited, "stationary duplicate pointer updates cannot consume the pending curve budget")
	print("Pending gesture CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
