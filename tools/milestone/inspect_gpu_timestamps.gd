extends SceneTree
## Bounded visible-device check. Does not claim pass timing when backend returns zero.
func _initialize() -> void:
	create_timer(60.0).timeout.connect(func():
		push_error("Timestamp inspection watchdog")
		quit(1))
	call_deferred("run")

func run() -> void:
	var editor: Node3D = load("res://scenes/editor.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	editor.set_process(false)
	var sim: Node3D = editor.sim
	sim.listen_to_time_controller = false
	sim.profile = true
	for frame in 20:
		sim.request_ticks(2)
		await RenderingServer.frame_post_draw
	var report: Dictionary = await sim.profile_report()
	print("GPU_TIMESTAMP_REPORT ", JSON.stringify(report))
	var ok: bool = report.has("available") and report.has("reason")
	if OS.get_name() == "macOS" and RenderingServer.get_current_rendering_driver_name().begins_with("metal"):
		ok = ok and not report.available and report.interval_ms.is_empty() and report.batch_count > 0
	print("GPU timestamp device: 1 checks, %d failures" % [0 if ok else 1])
	quit(0 if ok else 1)
