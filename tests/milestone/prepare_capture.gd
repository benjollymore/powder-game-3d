extends SceneTree
## Visible-frame regression: deferred edits must reach the next drawn image.
var _sim: Node3D
var _checks := 0
var _failures := 0

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(90.0).timeout.connect(func(): push_error("Capture regression timed out"); quit(1))
	call_deferred("_run")

func _run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	_sim = scene.get_node("SimVolume")
	_sim.listen_to_time_controller = false
	_sim.defer_render_preparation = true
	root.add_child(scene)
	current_scene = scene
	scene.get_node("Brush").set_process(false)
	scene.get_node("HUD").hide()
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.scaling_3d_scale = 1.0
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var rig: Node3D = scene.get_node("CameraRig")
	rig.frame_position = Vector3(0.85, 0.65, 0.85) * rig.world_size
	rig.frame_box(false)
	rig.set_process(false)
	for i in 20:
		await RenderingServer.frame_post_draw
	_sim.clear()
	await RenderingServer.frame_post_draw
	var empty: Image = root.get_texture().get_image()
	var n: int = VoxelCodec.GRID
	_sim.paint_region(Vector3i.ONE * (n / 4), Vector3i.ONE * (n * 3 / 4), Elements.Id.WALL)
	await RenderingServer.frame_post_draw
	var filled: Image = root.get_texture().get_image()
	var appeared := _changed_pixels(empty, filled)
	_check(appeared > 100, "pending wall appears in next drawn image (%d changed pixels)" % appeared)
	_check(not _sim._rt_derived_dirty, "draw consumed pending derived preparation")
	# Inspection-before-draw must preserve the same ordering too.
	_sim.clear()
	_sim.request_readback(func(_bytes): pass)
	await _sim.readback_ready
	await RenderingServer.frame_post_draw
	var cleared: Image = root.get_texture().get_image()
	var disappeared := _changed_pixels(filled, cleared)
	var residual := _changed_pixels(empty, cleared)
	_check(disappeared > 100, "clear plus inspection removes geometry in next drawn image (%d changed pixels)" % disappeared)
	_check(residual < 20, "restored empty viewport has no stale volume or shadow (%d residual pixels)" % residual)
	var directory := "res://docs/milestone/evidence-simulation/"
	empty.save_png(directory + "prepare-empty.png")
	filled.save_png(directory + "prepare-filled.png")
	cleared.save_png(directory + "prepare-cleared.png")
	print("PREPARE_CAPTURE grid=%d checks=%d failures=%d" % [n, _checks, _failures])
	scene.queue_free()
	for i in 3:
		await process_frame
	quit(1 if _failures else 0)

func _changed_pixels(a: Image, b: Image) -> int:
	var changed := 0
	for y in a.get_height():
		for x in a.get_width():
			var first := a.get_pixel(x, y)
			var second := b.get_pixel(x, y)
			if absf(first.r - second.r) + absf(first.g - second.g) + absf(first.b - second.b) > 0.1:
				changed += 1
	return changed

func _check(ok: bool, message: String) -> void:
	_checks += 1
	if ok:
		print("ok: " + message)
	else:
		_failures += 1
		push_error(message)
