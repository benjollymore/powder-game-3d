extends SceneTree
## Compare static editor presentation at the same exact physical state.
## -- grid=128 output_dir=/tmp/editor-quality
var output_dir := "/tmp/editor-quality"
var editor: Node3D
var sim: Node3D

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			output_dir = argument.trim_prefix("output_dir=")
	create_timer(90.0).timeout.connect(func():
		push_error("Quality capture watchdog")
		quit(1))
	call_deferred("run")

func read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func run() -> void:
	DirAccess.make_dir_recursive_absolute(output_dir)
	editor = load("res://scenes/editor.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	editor.set_process(false)
	editor.status.text = "BUILD · PAUSED"
	sim = editor.sim
	sim.listen_to_time_controller = false
	editor.guide.visible = false
	editor.marker.visible = false
	var bytes: PackedByteArray = Scenarios.build("Demo")
	editor.replace_authored(bytes)
	# Compare explicit profiles even when the editor has a saved preference.
	var original_scale: float = ProjectSettings.get_setting_with_override("rendering/scaling_3d/scale")
	var original_mode: int = ProjectSettings.get_setting_with_override("rendering/scaling_3d/mode")
	var original_aa: int = ProjectSettings.get_setting_with_override("rendering/anti_aliasing/quality/screen_space_aa")
	print("EDITOR_QUALITY_SETTINGS ", JSON.stringify({"project_mode": ProjectSettings.get_setting("rendering/scaling_3d/mode"),
		"platform_mode": original_mode, "editor_viewport_mode": root.scaling_3d_mode, "editor_scale": root.scaling_3d_scale}))
	var results: Array[Dictionary] = []
	var ok := true
	for view in ["front", "angle"]:
		editor.yaw = 0.0 if view == "front" else 0.65
		editor.pitch = 0.0 if view == "front" else -0.4
		editor._update_camera()
		for quality in ["default", "metalfx-fxaa", "native-fxaa", "native-smaa"]:
			root.scaling_3d_scale = original_scale if quality in ["default", "metalfx-fxaa"] else 1.0
			root.scaling_3d_mode = original_mode if quality == "default" else Viewport.SCALING_3D_MODE_METALFX_SPATIAL if quality == "metalfx-fxaa" else Viewport.SCALING_3D_MODE_BILINEAR
			root.screen_space_aa = original_aa if quality == "default" else Viewport.SCREEN_SPACE_AA_SMAA if quality == "native-smaa" else Viewport.SCREEN_SPACE_AA_FXAA
			for i in 30:
				await RenderingServer.frame_post_draw
			var capture := root.get_texture().get_image()
			var name: String = view + "-" + quality + ".png"
			ok = capture.save_png(output_dir.path_join(name)) == OK and ok
			results.append({"view": view, "quality": quality, "scale": root.scaling_3d_scale,
				"scaling_mode": root.scaling_3d_mode, "screen_aa": root.screen_space_aa,
				"image": name, "resolution": str(capture.get_size())})
			print("EDITOR_QUALITY ", JSON.stringify(results[-1]))
	ok = await read() == bytes and ok
	FileAccess.open(output_dir.path_join("captures.json"), FileAccess.WRITE).store_string(JSON.stringify(results, "  "))
	print("Editor quality: 1 checks, %d failures" % [0 if ok else 1])
	editor.queue_free()
	await process_frame
	await process_frame
	quit(0 if ok else 1)
