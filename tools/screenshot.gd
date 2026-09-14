extends SceneTree
## Capture a screenshot of the main scene after a few frames and quit.
## Usage: godot --path . -s res://tools/screenshot.gd -- /abs/out.png [frames] [cam_x,cam_y,cam_z] [look_x,look_y,look_z]

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out_path := args[0] if args.size() > 0 else "user://screenshot.png"
	var frames := int(args[1]) if args.size() > 1 else 60
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	if args.size() > 2:
		var parts := args[2].split(",")
		var rig := current_scene.get_node("CameraRig")
		rig.frame_position = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
		if args.size() > 3:
			var look := args[3].split(",")
			rig.orbit_target = Vector3(float(look[0]), float(look[1]), float(look[2]))
		rig.frame_box(false)
	for i in frames:
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png(out_path)
	print("screenshot %s -> %s (%d)" % [out_path, "ok" if err == OK else "FAILED", err])
	quit(0 if err == OK else 1)
