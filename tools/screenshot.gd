extends SceneTree
## Capture a screenshot of the main scene after a few frames and quit.
## Usage: godot --path . -s res://tools/screenshot.gd -- /abs/out.png [frames] [cam_x,cam_y,cam_z] [look_x,look_y,look_z]

func _initialize() -> void:
	# Positional args only; key=value args (e.g. scenario=Name) belong to the game,
	# except spin=deg (orbit the camera that much per frame, to show temporal
	# artifacts) and aa=fxaa|smaa|temporal|spatial|off (viewport AA / upscaler).
	var args := PackedStringArray()
	var spin := 0.0
	var aa := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("spin="):
			spin = float(a.substr(5))
		elif a.begins_with("aa="):
			aa = a.substr(3)
		elif not a.contains("="):
			args.append(a)
	var out_path := args[0] if args.size() > 0 else "user://screenshot.png"
	var frames := int(args[1]) if args.size() > 1 else 60
	change_scene_to_file("res://scenes/main.tscn")
	await process_frame
	await process_frame
	if aa != "":
		apply_aa(root.get_viewport(), aa)
	if args.size() > 2:
		var parts := args[2].split(",")
		# Camera and look-at are given in box widths so framings survive rescaling.
		var rig := current_scene.get_node("CameraRig")
		var w: float = rig.world_size
		rig.frame_position = Vector3(float(parts[0]), float(parts[1]), float(parts[2])) * w
		if args.size() > 3:
			var look := args[3].split(",")
			rig.orbit_target = Vector3(float(look[0]), float(look[1]), float(look[2])) * w
		rig.frame_box(false)
	var rig := current_scene.get_node("CameraRig")
	for i in frames:
		if spin != 0.0:
			var off: Vector3 = rig.position - rig.orbit_target
			rig.position = rig.orbit_target + off.rotated(Vector3.UP, deg_to_rad(spin))
			rig.look_at_target()
		await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var err := img.save_png(out_path)
	print("screenshot %s -> %s (%d)" % [out_path, "ok" if err == OK else "FAILED", err])
	quit(0 if err == OK else 1)


## Viewport anti-aliasing / upscaler presets shared by the tools.
static func apply_aa(vp: Viewport, mode: String) -> void:
	match mode:
		"off":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		"fxaa":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL
		"smaa":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL
		"spatial":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_SPATIAL
		"temporal":
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_METALFX_TEMPORAL
