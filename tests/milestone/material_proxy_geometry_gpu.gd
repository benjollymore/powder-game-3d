extends SceneTree
## GPU ray intervals measured in cell units against independent CPU boxes.
## This is fallback geometry/optical accounting, not a fluid model.
signal snapshot_ready(state: Dictionary)
var sim: Node3D
var camera: Camera3D
var checks := 0
var failures := 0
var rows: Array[Dictionary] = []
const OUT := "res://docs/milestone/material-capacity-evidence/geometry"
const TARGET := Vector3i(64,64,64)

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(120).timeout.connect(func(): push_error("Proxy geometry timeout"); quit(2))
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(320,320)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var stage := Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	for name in ["Splats","Leaves","Droplets"]: sim.get_node(name).capacity = 1
	stage.add_child(sim)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.far = 100.0
	camera.fov = 45
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLACK
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	for i in 20: await process_frame
	var volume_source := FileAccess.get_file_as_string("res://shaders/spatial/voxel_volume.gdshader")
	volume_source = volume_source.replace("\tif (volume_debug == 3) {", "\tif (volume_debug == 4) { ALBEDO = vec3(liquid_len / 4.0); ALPHA = 1.0; }\n\tif (volume_debug == 3) {")
	var shader := Shader.new()
	shader.code = volume_source
	sim.get_node("VolumeMesh").material_override.shader = shader
	sim.set_param("physical_overflow",sim._physical_overflow_texture)
	sim.set_param("volume_debug",4)
	var cell_size: float = sim.world_size()/VoxelCodec.GRID
	var center := (Vector3(TARGET)+Vector3.ONE*0.5-Vector3.ONE*VoxelCodec.GRID*0.5)*cell_size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for amount in [1,50,100,200,255]:
		var data := WorldBuilder.empty()
		for p in [TARGET,Vector3i(8,8,8)]:
			data[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(Elements.Id.WATER,17,amount)|(1<<24)
		var bytes := data.to_byte_array()
		sim.upload(bytes)
		var fill := float(amount)/Elements.LIQUID_FULL
		var side := pow(minf(fill,1.0),1.0/3.0)
		var half_size := Vector3.ONE*side*0.5*cell_size
		for view in ["front","oblique","inside","cap-x","cap-y","cap-z","removed"]:
			var offset := Vector3(0,0,3)
			var up := Vector3.UP
			var section_axis := 2
			if view=="oblique": offset = Vector3(2,1,3)
			if view=="inside": offset = Vector3.ZERO
			if view=="cap-x": offset = Vector3(3,0,0); section_axis = 0
			if view=="cap-y": offset = Vector3(0,3,0); section_axis = 1; up = Vector3.FORWARD
			camera.position = center+offset*cell_size
			camera.look_at(center+Vector3(0,0,-cell_size) if view=="inside" else center,up)
			sim.set_param("section_enabled",view.begins_with("cap-") or view=="removed")
			sim.set_param("section_axis",section_axis)
			sim.set_param("section_cell",63 if view=="removed" else 64)
			for i in 5: await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var tested := 0
			var wrong := 0
			var max_error := 0.0
			for y in range(4,316,4):
				for x in range(4,316,4):
					var pixel := Vector2(x+0.5,y+0.5)
					var origin := camera.project_ray_origin(pixel)
					var direction := camera.project_ray_normal(pixel)
					var interval := _interval(origin,direction,center-half_size,center+half_size)
					var length := maxf(interval.y-maxf(interval.x,0.0),0.0)/cell_size*maxf(fill,1.0)
					if view=="removed": length = 0
					# The distant second cell is real physical matter too. One
					# oblique ray hits it: the reference must include both boxes.
					var other := (Vector3.ONE*8.5-Vector3.ONE*VoxelCodec.GRID*0.5)*cell_size
					var other_interval := _interval(origin,direction,other-half_size,other+half_size)
					length += maxf(other_interval.y-maxf(other_interval.x,0.0),0.0)/cell_size*maxf(fill,1.0)
					# Exclude silhouettes: raster pixel-center/FP32 disagreement is
					# separate from length integration, and isn't hidden in tolerance.
					if length>0 and length<0.04: continue
					var actual := image.get_pixel(x,y).srgb_to_linear().r*4.0
					var error := absf(actual-length)
					max_error = maxf(max_error,error)
					tested += 1
					if error>0.035: wrong += 1
			_check(tested>500,"enough independent ray probes")
			_check(wrong==0,"amount%d %s analytic optical interval"%[amount,view])
			var row := {"amount":amount,"view":view,"samples":tested,"wrong":wrong,"max_error_cells":max_error,"tolerance_cells":0.035}
			rows.append(row)
			print(JSON.stringify(row))
			_check(image.save_png(OUT+"/amount%d-%s.png"%[amount,view])==OK,"save analytic capture")
		RenderingServer.call_on_render_thread(_rt_snapshot)
		var state: Dictionary = await snapshot_ready
		_check(state.voxels==bytes,"all physical bytes unchanged by proxy rendering")
		_check(state.overflow[2]==255,"actual droplet overflow active")
	await _opaque_geometry(center,cell_size)
	var file := FileAccess.open(OUT+"/regression.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	print("PROXY_GEOMETRY_CHECKS %d FAILURES %d"%[checks,failures])
	quit(0 if failures==0 else 1)

func _opaque_geometry(center: Vector3, cell_size: float) -> void:
	var source := FileAccess.get_file_as_string("res://shaders/spatial/voxel_opaque.gdshader")
	source = source.replace("	if (debug_mode == 8)", "	if (debug_mode == 9) { ALBEDO = vec3(0.0); EMISSION = vec3(1.0); }\n	if (debug_mode == 8)")
	var shader := Shader.new()
	shader.code = source
	sim.get_node("Mesh").material_override.shader = shader
	sim.set_param("physical_overflow",sim._physical_overflow_texture)
	sim.set_param("debug_mode",9)
	sim.set_param("volume_debug",0)
	for element in [Elements.Id.SAND,Elements.Id.PLANT]:
		var data := WorldBuilder.empty()
		for p in [TARGET,Vector3i(8,8,8)]:
			data[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(element,17,0)|((6 if element==Elements.Id.SAND else 0)<<24)
		var bytes := data.to_byte_array()
		sim.upload(bytes)
		for view in ["front","oblique","inside","cap-x","cap-y","cap-z","removed"]:
			var offset := Vector3(0,0,3)
			var up := Vector3.UP
			var axis := 2
			if view=="oblique": offset = Vector3(2,1,3)
			if view=="inside": offset = Vector3.ZERO
			if view=="cap-x": offset = Vector3(3,0,0); axis = 0
			if view=="cap-y": offset = Vector3(0,3,0); axis = 1; up = Vector3.FORWARD
			camera.position = center+offset*cell_size
			camera.look_at(center+Vector3(0,0,-cell_size) if view=="inside" else center,up)
			sim.set_param("section_enabled",view.begins_with("cap-") or view=="removed")
			sim.set_param("section_axis",axis)
			sim.set_param("section_cell",63 if view=="removed" else 64)
			for i in 5: await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var wrong := 0
			var tested := 0
			for y in range(4,316,4):
				for x in range(4,316,4):
					var pixel := Vector2(x+0.5,y+0.5)
					var interval := _interval(camera.project_ray_origin(pixel),camera.project_ray_normal(pixel),center-Vector3.ONE*cell_size*0.5,center+Vector3.ONE*cell_size*0.5)
					var length := maxf(interval.y-maxf(interval.x,0.0),0.0)/cell_size
					if length>0 and length<0.04: continue
					var expected: bool = length>0 and view!="removed"
					var other := (Vector3.ONE*8.5-Vector3.ONE*VoxelCodec.GRID*0.5)*cell_size
					var other_interval := _interval(camera.project_ray_origin(pixel),camera.project_ray_normal(pixel),other-Vector3.ONE*cell_size*0.5,other+Vector3.ONE*cell_size*0.5)
					expected = expected or other_interval.y>maxf(other_interval.x,0.0)
					if (image.get_pixel(x,y).r>0.5)!=expected: wrong += 1
					tested += 1
			_check(wrong==0,"element%d %s exact opaque fallback coverage"%[element,view])
			rows.append({"element":element,"view":view,"samples":tested,"wrong_coverage":wrong})
			_check(image.save_png(OUT+"/element%d-%s.png"%[element,view])==OK,"save opaque capture")
		RenderingServer.call_on_render_thread(_rt_snapshot)
		var state: Dictionary = await snapshot_ready
		_check(state.voxels==bytes,"opaque fallback preserves physical bytes")

func _interval(origin: Vector3, direction: Vector3, lower: Vector3, upper: Vector3) -> Vector2:
	var enter := -INF
	var exit := INF
	for axis in 3:
		if absf(direction[axis])<1e-10:
			if origin[axis]<lower[axis] or origin[axis]>upper[axis]: return Vector2(1,0)
			continue
		var a := (lower[axis]-origin[axis])/direction[axis]
		var b := (upper[axis]-origin[axis])/direction[axis]
		enter = maxf(enter,minf(a,b))
		exit = minf(exit,maxf(a,b))
	return Vector2(enter,exit)

func _rt_snapshot() -> void:
	sim._rt_flush_render_preparation()
	snapshot_ready.emit.call_deferred({"voxels":sim._rd.texture_get_data(sim._grid_rid,0),"overflow":sim._rd.texture_get_data(sim._physical_overflow_rid,0)})

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures += 1; push_error(message)
