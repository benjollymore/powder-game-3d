extends SceneTree
## Compare integrated liquid length against analytic frozen box intersections.
## godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_liquid_edges_gpu.gd -- grid=128
const OUT := "res://docs/milestone/liquid-edge-evidence"
const BASELINE := "res://tests/milestone/fixtures/voxel_volume_edge_baseline.gdshader"
const FIXED := "res://shaders/spatial/voxel_volume.gdshader"
var sim: Node3D
var camera: Camera3D
var checks := 0
var failures := 0
var rows: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func _shader(path: String) -> Shader:
	var source := FileAccess.get_file_as_string(path)
	source = source.replace("float dbg_leaps = 0.0;", "float dbg_leaps = 0.0;\n\tfloat dbg_missed_exit = 0.0;")
	source = source.replace("\t\tf_prev = f;", "\t\tif (in_liquid && !liquid && !prev_liquid && f < 0.5) { dbg_missed_exit = 1.0; }\n\t\tf_prev = f;")
	source = source.replace("\tif (volume_debug == 3) {", "\tif (volume_debug == 4) { ALBEDO = vec3(dbg_missed_exit, 0.0, 0.0); ALPHA = 1.0; }\n\tif (volume_debug == 5) { ALBEDO = vec3(liquid_len / G); ALPHA = 1.0; }\n\tif (volume_debug == 3) {")
	var shader := Shader.new()
	shader.code = source
	return shader

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
	camera.fov = 50
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color(0.08,0.12,0.18)
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	for i in 30:
		await process_frame
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var shaders := [_shader(BASELINE),_shader(FIXED)]
	var cases: Array[Dictionary] = []
	for axis in 3:
		for oblique in [false,true]:
			var position := Vector3.ZERO
			position[axis] = 1.2
			if oblique:
				position[(axis+1)%3] = 0.3
				position[(axis+2)%3] = 0.2
			cases.append({"name":"cap-%d-%s"%[axis,"oblique" if oblique else "front"],"axis":axis,"section":true,"thin":false,"camera":position})
	cases.append({"name":"ordinary-front","axis":2,"section":false,"thin":false,"camera":Vector3(0,0,1.2)})
	cases.append({"name":"ordinary-oblique","axis":2,"section":false,"thin":false,"camera":Vector3(0.3,0.2,1.2)})
	cases.append({"name":"thin-cap","axis":2,"section":true,"thin":true,"camera":Vector3(0.3,0.2,1.2)})
	cases.append({"name":"thin-ordinary","axis":2,"section":false,"thin":true,"camera":Vector3(0.3,0.2,1.2)})
	for c in cases:
		var lo := Vector3i.ONE*VoxelCodec.GRID/8
		var hi := Vector3i.ONE*VoxelCodec.GRID*7/8
		if c.thin:
			lo.y = VoxelCodec.GRID/2-1
			hi.y = VoxelCodec.GRID/2
		var data := WorldBuilder.empty()
		WorldBuilder.fill_box(data,lo,hi,Elements.Id.WATER)
		var bytes := data.to_byte_array()
		sim.upload(bytes)
		sim.set_param("section_enabled",c.section)
		sim.set_param("section_axis",c.axis)
		sim.set_param("section_cell",VoxelCodec.GRID/2-1)
		camera.position = c.camera * sim.world_size()
		camera.look_at(Vector3.ZERO,Vector3.FORWARD if c.axis==1 else Vector3.UP)
		var clip_hi := hi
		if c.section:
			clip_hi[c.axis] = VoxelCodec.GRID/2
		var probes := _analytic_probes(lo,clip_hi)
		_check(probes.size()>100,c.name+" has analytic interior samples")
		for variant in 2:
			var material: ShaderMaterial = sim.get_node("VolumeMesh").material_override
			material.shader = shaders[variant]
			var row := {"case":c.name,"variant":"baseline" if variant==0 else "fixed","samples":probes.size()}
			for mode in [0,4,5]:
				sim.set_param("volume_debug",mode)
				for i in 12:
					await process_frame
				await RenderingServer.frame_post_draw
				var img := root.get_texture().get_image()
				var suffix: String = {0:"normal",4:"missed-exit",5:"length"}[mode]
				_check(img.save_png(OUT+"/%s-%s-%s.png"%[c.name,row.variant,suffix])==OK,"save "+c.name+" "+row.variant+" "+suffix)
				if mode==4:
					var marked := 0
					for p in probes:
						if img.get_pixelv(p.pixel).r>0.5:
							marked += 1
					row["missed_exits"] = marked
				if mode==5:
					var max_error := 0.0
					var wrong := 0
					for p in probes:
						# Output is sRGB8; allow 0.75 cell for encoding + four bisections.
						var measured := img.get_pixelv(p.pixel).srgb_to_linear().r*VoxelCodec.GRID
						var error := absf(measured-float(p.length))
						max_error = maxf(max_error,error)
						if error>0.75:
							wrong += 1
					row["wrong_lengths"] = wrong
					row["max_length_error_cells"] = max_error
			rows.append(row)
			print(JSON.stringify(row))
			if variant==1:
				_check(row.missed_exits==0,c.name+" no open liquid after density exit")
				_check(row.wrong_lengths==0,c.name+" liquid length matches analytic box")
			elif c.name in ["cap-2-front","cap-2-oblique"]:
				_check(row.missed_exits>0 and row.wrong_lengths>0,c.name+" reproduces missed-exit/path error")
		var readback: Array[PackedByteArray] = []
		sim.request_readback(func(b: PackedByteArray): readback.append(b))
		var deadline := Time.get_ticks_msec()+15000
		while readback.is_empty() and Time.get_ticks_msec()<deadline:
			await process_frame
		_check(not readback.is_empty() and readback[0]==bytes,c.name+" full physical bytes unchanged")
	var file := FileAccess.open(OUT+"/regression.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	print("LIQUID_EXIT_CHECKS %d FAILURES %d"%[checks,failures])
	quit(0 if failures==0 else 1)

func _analytic_probes(lo: Vector3i, hi: Vector3i) -> Array[Dictionary]:
	var probes: Array[Dictionary] = []
	var size: float = sim.world_size()
	var cell := size/VoxelCodec.GRID
	var lower := (Vector3(lo)/VoxelCodec.GRID-Vector3.ONE*0.5)*size
	var upper := (Vector3(hi)/VoxelCodec.GRID-Vector3.ONE*0.5)*size
	for y in range(2,root.size.y-2,2):
		for x in range(2,root.size.x-2,2):
			var pixel := Vector2(x+0.5,y+0.5)
			var origin := camera.project_ray_origin(pixel)
			var direction := camera.project_ray_normal(pixel)
			var enter := -INF
			var exit := INF
			var enter_axis := 0
			var exit_axis := 0
			for axis in 3:
				if absf(direction[axis])<1e-10:
					if origin[axis]<=lower[axis] or origin[axis]>=upper[axis]:
						exit = -INF
					continue
				var a: float = (lower[axis]-origin[axis])/direction[axis]
				var b: float = (upper[axis]-origin[axis])/direction[axis]
				if minf(a,b)>enter:
					enter = minf(a,b)
					enter_axis = axis
				if maxf(a,b)<exit:
					exit = maxf(a,b)
					exit_axis = axis
			if enter<0 or exit<=enter:
				continue
			var safe := true
			for hit in [{"t":enter,"axis":enter_axis},{"t":exit,"axis":exit_axis}]:
				var point: Vector3 = origin+direction*float(hit.t)
				for axis in 3:
					if axis==hit.axis:
						continue
					var margin := minf(2*cell,(upper[axis]-lower[axis])*0.2)
					if point[axis]<lower[axis]+margin or point[axis]>upper[axis]-margin:
						safe = false
			if safe:
				probes.append({"pixel":Vector2i(x,y),"length":(exit-enter)/cell})
	return probes

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print(("ok: " if ok else "FAIL: ")+message)
