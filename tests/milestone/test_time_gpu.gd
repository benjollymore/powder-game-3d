extends SceneTree
var lab: Node3D
var sim: Node3D
var clock: Node
var checks := 0
var failures := 0
func _initialize() -> void:
	create_timer(60.0).timeout.connect(func(): quit(1))
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1
func read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready
func run() -> void:
	lab = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(lab)
	current_scene = lab
	sim = lab.sim
	clock = root.get_node("TimeController")
	clock.set_process(false) # Deterministically drive the real time API below.
	for i in 8:
		await RenderingServer.frame_post_draw
	var original := await read()
	lab.run_or_restore()
	while lab.capturing:
		await process_frame
	check(lab.testing and lab.build_snapshot == original, "Run retains exact authored bytes before any Test ticks")
	clock._process(1.0 / clock.TICKS_PER_SECOND)
	await read()
	var running_tick: int = sim.tick
	lab.pause_button.pressed.emit()
	var paused_bytes := await read()
	for i in 5:
		clock._process(0.5)
		await process_frame
	check(sim.tick == running_tick and await read() == paused_bytes, "Pause preserves actual voxel bytes and tick across later frames")
	check(lab._test_phase() == "TEST · PAUSED" and lab.test_time_controls.visible, "paused Test remains visible and distinct from Build")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/editor-paused-1280x800.png")
	lab.step_button.pressed.emit()
	clock._process(0.0)
	await read()
	check(sim.tick == running_tick + 1 and clock.paused, "Single step advances the production simulation exactly one tick")
	lab.pause_button.pressed.emit()
	clock._process(2.0 / clock.TICKS_PER_SECOND)
	await read()
	check(sim.tick == running_tick + 3 and not clock.paused, "Resume continues the same Test without restoring or restarting it")
	check(lab.build_snapshot == original, "pause, step and resume never overwrite the authored snapshot")
	lab.step_test() # Step remains pending until the controller's next frame.
	lab.run_or_restore()
	clock._process(0.0)
	check(not lab.testing and clock.paused and await read() == original,
		"Return from paused Test restores exact authored bytes and cancels a pending step")
	lab.step_test()
	lab.toggle_test_pause()
	clock._process(1.0)
	check(sim.tick == 0 and await read() == original, "Build guards prevent later step/pause actions from advancing the restored world")
	print("Test time GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
