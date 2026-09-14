extends SceneTree
## Section-plane ownership test using controlled presentation instances.
## No simulation state is created or changed by these shader-only fixtures.
var stage: Node3D
var card: MultiMeshInstance3D
var failures := 0
var checks := 0
var rows: Array[Dictionary] = []
var OUT := "res://docs/milestone/rendering-evidence"

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			OUT = argument.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	call_deferred("_run")

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(600, 600)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	stage = Node3D.new()
	root.add_child(stage)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLACK
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 1.0
	stage.add_child(world)
	var camera := Camera3D.new()
	camera.position = Vector3(0,0,0.7)
	camera.fov = 45.0
	stage.add_child(camera)
	camera.look_at(Vector3.ZERO)
	card = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = 1
	card.multimesh = mm
	stage.add_child(card)
	for role in ["splat", "droplet", "leaf", "fx"]:
		for center in [-0.02, 0.02]:
			var y := -0.1 if role == "leaf" else 0.0
			mm.set_instance_transform(0, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * 0.2), Vector3(center,y,0)))
			var id := Elements.Id.PLANT if role == "leaf" else (Elements.Id.WATER if role == "droplet" else Elements.Id.SAND)
			mm.set_instance_custom_data(0, Color(id,0.4,0.0,4.0) if role != "fx" else Color(1,0.5,0.4,0))
			for baseline in [true, false]:
				var material := ShaderMaterial.new()
				material.shader = load("res://tests/milestone/fixtures/" + role + "_baseline.gdshader") if baseline else load("res://shaders/spatial/" + role + ".gdshader")
				material.set_shader_parameter("palette", Elements.palette())
				material.set_shader_parameter("section_enabled", true)
				material.set_shader_parameter("section_axis", 0)
				material.set_shader_parameter("section_cell", 63)
				material.set_shader_parameter("grid_size", 128)
				card.material_override = material
				for i in 12:
					await process_frame
				await RenderingServer.frame_post_draw
				var img := root.get_texture().get_image()
				var counts := _count_sides(img)
				var row := {"role":role, "center":center, "variant":"baseline" if baseline else "fixed", "kept_side_pixels":counts.x, "clipped_side_pixels":counts.y}
				rows.append(row)
				print(JSON.stringify(row))
				var name: String = role + ("-inside" if center < 0 else "-outside") + "-" + row.variant
				_check(img.save_png(OUT + "/sprite-section-" + name + ".png") == OK, "capture " + name)
				if baseline:
					_check(counts.y > 100 if center < 0 else counts.x == 0, name + " reproduces center-clipping defect")
				else:
					_check(counts.y == 0, name + " geometry does not protrude across section")
					_check(counts.x > 100, name + " preserves geometry on retained side")
	var file := FileAccess.open(OUT + "/sprite-section-metrics.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	print("SPRITE_SECTION_CHECKS %d FAILURES %d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _count_sides(img: Image) -> Vector2i:
	var count := Vector2i.ZERO
	for y in range(180,420):
		for x in range(170,430):
			if abs(x - 300) < 2:
				continue
			var c := img.get_pixel(x,y)
			if c.r + c.g + c.b > 0.06:
				if x < 300:
					count.x += 1
				else:
					count.y += 1
	return count

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print(("ok: " if ok else "FAIL: ") + message)
