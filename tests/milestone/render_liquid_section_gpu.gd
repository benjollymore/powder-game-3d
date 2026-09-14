extends SceneTree
## Actual post-volume depth occlusion with transparent red probe geometry.
## godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_liquid_section_gpu.gd -- grid=128
const BASELINE := preload("res://tests/milestone/fixtures/voxel_volume_baseline.gdshader")
const FIXED := preload("res://shaders/spatial/voxel_volume.gdshader")
var OUT := "res://docs/milestone/liquid-section-evidence"
var sim: Node3D
var camera: Camera3D
var probe: MeshInstance3D
var failures := 0
var checks := 0
var rows: Array[Dictionary] = []

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			OUT = argument.trim_prefix("output_dir=")
	call_deferred("_run")

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(600,600)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var stage := Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	stage.add_child(sim)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.fov = 50.0
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.08,0.12,0.18)
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	probe = MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * sim.world_size() * 0.14
	probe.mesh = quad
	var probe_material := StandardMaterial3D.new()
	probe_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	probe_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	probe_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	probe_material.albedo_color = Color(1,0,0,1)
	probe_material.render_priority = 10 # after the transparent voxel volume
	probe.material_override = probe_material
	stage.add_child(probe)
	for i in 30:
		await process_frame
	var d := WorldBuilder.empty()
	WorldBuilder.fill_box(d,Vector3i.ONE*VoxelCodec.GRID/8,Vector3i.ONE*VoxelCodec.GRID*7/8,Elements.Id.WATER)
	var before := d.to_byte_array()
	sim.upload(before)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for view in [{"axis":0,"name":"axis-0","offset":Vector3.ZERO},{"axis":1,"name":"axis-1","offset":Vector3.ZERO},{"axis":2,"name":"axis-2","offset":Vector3.ZERO},{"axis":2,"name":"axis-2-oblique","offset":Vector3(0.3,0.2,0)}]:
		var axis: int = view.axis
		for section in [false,true]:
			sim.set_param("section_enabled",section)
			sim.set_param("section_axis",axis)
			sim.set_param("section_cell",VoxelCodec.GRID/2-1)
			var direction := Vector3.ZERO
			direction[axis] = 1.0
			camera.position = (direction * 1.2 + Vector3(view.offset)) * sim.world_size()
			var up := Vector3.FORWARD if axis==1 else Vector3.UP
			camera.look_at(Vector3.ZERO,up)
			for in_front in [false,true]:
				var surface := 0.0 if section else 0.375
				probe.position = direction * sim.world_size() * (surface + (0.01 if in_front else -0.01))
				probe.look_at(probe.position + direction,up)
				var baseline_img: Image
				for baseline in [true,false]:
					var material: ShaderMaterial = sim.get_node("VolumeMesh").material_override
					material.shader = BASELINE if baseline else FIXED
					for i in 12:
						await process_frame
					await RenderingServer.frame_post_draw
					var img := root.get_texture().get_image()
					var visible := _red_pixels(img)
					var row := {"axis":axis,"view":view.name,"section":section,"in_front":in_front,"variant":"baseline" if baseline else "fixed","red_probe_pixels":visible}
					rows.append(row)
					print(JSON.stringify(row))
					var name: String = "%s-%s-%s-%s" % [view.name,"section" if section else "ordinary","front" if in_front else "behind",row.variant]
					_check(img.save_png(OUT + "/" + name + ".png")==OK,"capture " + name)
					if baseline:
						baseline_img = img
						if section and not in_front:
							_check(visible==121,name + " reproduces behind-cap depth leak")
					else:
						_check(visible==(121 if in_front else 0),name + " has correct front/behind depth occlusion")
						if not section:
							_check(img.get_data()==baseline_img.get_data(),name + " ordinary rendering is pixel-identical")
	var result: Array[PackedByteArray] = []
	sim.request_readback(func(bytes: PackedByteArray): result.append(bytes))
	var deadline := Time.get_ticks_msec()+15000
	while result.is_empty() and Time.get_ticks_msec()<deadline:
		await process_frame
	_check(not result.is_empty() and result[0]==before,"all liquid physical bytes unchanged")
	var file := FileAccess.open(OUT+"/metrics.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	print("LIQUID_SECTION_CHECKS %d FAILURES %d" % [checks,failures])
	quit(0 if failures==0 else 1)

func _red_pixels(img: Image) -> int:
	var count := 0
	var center := Vector2i(camera.unproject_position(probe.position).round())
	for y in range(center.y-5,center.y+6):
		for x in range(center.x-5,center.x+6):
			var c := img.get_pixel(x,y)
			if c.r>0.8 and c.g<0.1 and c.b<0.1:
				count += 1
	return count

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print(("ok: " if ok else "FAIL: ")+message)
