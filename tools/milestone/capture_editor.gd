extends SceneTree
## Capture the configured application entrypoint, not an isolated material stage.
var editor: Node3D
var directory := "res://docs/milestone/editor-current"

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			directory = argument.trim_prefix("output_dir=")
	create_timer(60.0).timeout.connect(func():
		push_error("Editor capture watchdog expired")
		quit(1))
	call_deferred("run")

func draw_frames(count: int) -> void:
	for i in count:
		await RenderingServer.frame_post_draw

func capture(name: String) -> void:
	await draw_frames(4)
	var image := root.get_texture().get_image()
	var path := directory.path_join(name + ".png")
	if image.is_empty() or image.save_png(path) != OK:
		push_error("Could not capture " + path)
		quit(1)
	print("EDITOR_CAPTURE ", path, " ", image.get_size())

func run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	editor = load(ProjectSettings.get_setting("application/run/main_scene")).instantiate()
	root.add_child(editor)
	current_scene = editor
	await draw_frames(20)
	print("EDITOR_DISPLAY scale=", root.scaling_3d_scale, " mode=", root.scaling_3d_mode, " aa=", root.screen_space_aa)
	await capture("build-front")
	editor.yaw = 0.65
	editor.pitch = -0.4
	editor._update_camera()
	await capture("build-angle")
	editor.run_or_restore()
	while editor.capturing:
		await process_frame
	editor.toggle_test_pause()
	await capture("test-paused")
	editor.run_or_restore()
	await capture("returned-build")
	while editor.capturing:
		await process_frame
	editor.advanced_toggle.button_pressed = true
	await capture("construction-and-picture")
	print("EDITOR_CAPTURE complete")
	editor.queue_free()
	await process_frame
	await process_frame
	quit(0)
