extends "res://tests/milestone/material_proxy_geometry_gpu.gd"
## Defaults to the pinned historical omission; candidate=1 validates the rescue.
signal picked(result: Dictionary)
const PROBE_OUT := "res://docs/milestone/ordinary-liquid-evidence/baseline"

func _run() -> void:
	var candidate := "candidate=1" in OS.get_cmdline_user_args()
	var destination := PROBE_OUT if !candidate else "res://docs/milestone/ordinary-liquid-evidence/fixed"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): destination = arg.trim_prefix("output_dir=")
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
	stage.add_child(sim)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.far = 100
	camera.fov = 45
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	for i in 20: await process_frame
	var source := FileAccess.get_file_as_string("res://shaders/spatial/voxel_volume.gdshader" if candidate else "res://docs/milestone/ordinary-liquid-evidence/original/voxel_volume.gdshader.txt")
	source = source.replace("\tif (volume_debug == 3) {", "\tif (volume_debug == 4) { ALBEDO = vec3(liquid_len / 4.0); ALPHA = 1.0; }\n\tif (volume_debug == 3) {")
	var shader := Shader.new()
	shader.code = source
	sim.get_node("VolumeMesh").material_override.shader = shader
	sim.set_param("physical_overflow",sim._physical_overflow_texture)
	var cell_size: float = sim.world_size()/VoxelCodec.GRID
	var center := (Vector3(TARGET)+Vector3.ONE*0.5-Vector3.ONE*VoxelCodec.GRID*0.5)*cell_size
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination))
	var results: Array[Dictionary] = []
	for element in [Elements.Id.WATER,Elements.Id.OIL]:
		for amount in [1,50,100,150,200,255]:
			for shape in ["single","sheet-y","sheet-x"]:
				var data := WorldBuilder.empty()
				var cells: Array[Vector3i] = []
				if shape=="single":
					cells.append(TARGET)
				else:
					for a in range(-2,3):
						for b in range(-2,3):
							cells.append(TARGET+(Vector3i(a,0,b) if shape=="sheet-y" else Vector3i(0,a,b)))
				for p in cells:
					data[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(element,17,amount)
				var bytes := data.to_byte_array()
				sim.upload(bytes)
				for i in 3: await process_frame
				RenderingServer.call_on_render_thread(_rt_probe_snapshot.bind(cells))
				var state: Dictionary = await snapshot_ready
				_check(state.voxels==bytes,"exact ordinary physical bytes retained")
				_check(state.droplets==0 and state.eligible==0 and state.overflow==0,"ordinary liquid uses no droplet or overflow fallback")
				for angle in ["front","oblique"]:
					var axis := 1 if shape=="sheet-y" else (0 if shape=="sheet-x" else 2)
					var offset := Vector3.ZERO
					offset[axis] = 3 if shape=="single" else 8
					if angle=="oblique":
						offset[(axis+1)%3] = 0.8
						offset[(axis+2)%3] = 0.5
					camera.position = center+offset*cell_size
					camera.look_at(center,Vector3.FORWARD if axis==1 else Vector3.UP)
					var ray := {"origin":camera.position/sim.world_size(),"direction":(center-camera.position).normalized(),"mask":1<<element}
					sim.request_surface_pick(ray,0,true,func(result: Dictionary): picked.emit(result))
					var pick: Dictionary = await picked
					_check(pick.valid and pick.element==element,"authoritative picking finds ordinary liquid")
					var row := {"element":element,"amount":amount,"shape":shape,"angle":angle,"physical_cells":cells.size(),"field_peak_byte":state.peak,"picked":str(pick.hit),"voxel_sha256":_sha256(bytes)}
					for mode in [0,4]:
						sim.set_param("volume_debug",mode)
						for i in 4: await process_frame
						await RenderingServer.frame_post_draw
						var image := root.get_texture().get_image()
						var name: String = "%d-%d-%s-%s-%s"%[element,amount,shape,angle,"normal" if mode==0 else "length"]
						_check(image.save_png(destination+"/"+name+".png")==OK,"save ordinary liquid reproduction")
						if mode==4:
							var represented := 0
							for y in image.get_height():
								for x in image.get_width():
									if image.get_pixel(x,y).r>0.0: represented += 1
							row.liquid_pixels = represented
							if !candidate and shape=="single": _check(represented==0,"reproduces ordinary single-cell omission")
							if candidate:
								var analytic := _slab_probes(image,cells,amount,cell_size)
								row.analytic = analytic
								_check(analytic.wrong==0,"ordinary slab analytic path and coverage")
								if amount>=50: _check(represented>0,"ordinary visible material retained")
					results.append(row)
					print(JSON.stringify(row))
	# Documented negative control (reviewer finding): falling liquid with more
	# than two wet face neighbours is neither spray (no droplet sprite) nor
	# rescued by the ordinary thin classifier, which excludes the falling flag.
	# A one-cell partial sheet dropping as a unit stays pickable but invisible
	# in the volume pass. Corner cells (two wet neighbours) do go to droplets;
	# they are hidden here so only volume-pass coverage is measured.
	if candidate:
		var falling := WorldBuilder.empty()
		var sheet: Array[Vector3i] = []
		for a in range(-2,3):
			for b in range(-2,3):
				var p := TARGET+Vector3i(0,a,b)
				falling[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(Elements.Id.WATER,17,50)|(1<<24)
				sheet.append(p)
		var falling_bytes := falling.to_byte_array()
		sim.upload(falling_bytes)
		for i in 3: await process_frame
		RenderingServer.call_on_render_thread(_rt_probe_snapshot.bind(sheet))
		var falling_state: Dictionary = await snapshot_ready
		_check(falling_state.voxels==falling_bytes,"falling sheet physical bytes retained")
		camera.position = center+Vector3(8,0,0)*cell_size
		camera.look_at(center,Vector3.UP)
		var ray := {"origin":camera.position/sim.world_size(),"direction":(center-camera.position).normalized(),"mask":1<<Elements.Id.WATER}
		sim.request_surface_pick(ray,0,true,func(result: Dictionary): picked.emit(result))
		var falling_pick: Dictionary = await picked
		_check(falling_pick.valid and falling_pick.element==Elements.Id.WATER,"falling partial sheet remains pickable")
		sim.get_node("Droplets").visible = false
		sim.set_param("volume_debug",4)
		for i in 4: await process_frame
		await RenderingServer.frame_post_draw
		var falling_image := root.get_texture().get_image()
		var falling_pixels := 0
		for y in falling_image.get_height():
			for x in falling_image.get_width():
				if falling_image.get_pixel(x,y).r>0.0: falling_pixels += 1
		# Recorded diagnostic only: zero pixels documents the limitation and must not become a requirement.
		print("DIAGNOSTIC falling non-spray partial sheet volume-pass pixels=%d (limitation, not a gate)"%falling_pixels)
		_check(falling_image.save_png(destination+"/falling-sheet-50-front-length.png")==OK,"save falling sheet negative control")
		sim.get_node("Droplets").visible = true
		results.append({"case":"falling-non-spray-sheet-negative-control","amount":50,"physical_cells":sheet.size(),"liquid_pixels":falling_pixels,"droplets":falling_state.droplets,"eligible":falling_state.eligible,"picked":str(falling_pick.hit),"voxel_sha256":_sha256(falling_bytes),"limitation":"falling flag excluded from thin rescue; only corner cells (<=2 wet neighbours) become droplet sprites"})
	# Exercise the real radius-zero edit entry point while paused, rather than
	# only uploading a reconstructed test array. Seed is recorded after paint.
	sim.upload(WorldBuilder.empty().to_byte_array())
	for i in 3: await process_frame
	sim.paint(TARGET,0,Elements.Id.WATER)
	for i in 3: await process_frame
	RenderingServer.call_on_render_thread(_rt_probe_snapshot.bind([TARGET]))
	var painted: Dictionary = await snapshot_ready
	var index := VoxelCodec.index(TARGET.x,TARGET.y,TARGET.z)*4
	_check(painted.voxels[index]==Elements.Id.WATER and painted.voxels[index+2]==200 and painted.voxels[index+3]==0,"actual paused radius-zero edit creates full ordinary water")
	_check(painted.droplets==0,"painted ordinary water has no physical sprite")
	camera.position = center+Vector3(0,0,3)*cell_size
	camera.look_at(center,Vector3.UP)
	sim.set_param("volume_debug",4)
	for i in 4: await process_frame
	await RenderingServer.frame_post_draw
	var painted_image := root.get_texture().get_image()
	var painted_pixels := 0
	for y in painted_image.get_height():
		for x in painted_image.get_width():
			if painted_image.get_pixel(x,y).r>0.0: painted_pixels += 1
	_check((painted_pixels>0) if candidate else (painted_pixels==0),"actual paused radius-zero water coverage")
	_check(painted_image.save_png(destination+"/actual-radius-zero-paint-length.png")==OK,"save actual paint omission")
	results.append({"case":"actual-radius-zero-paint","liquid_pixels":painted_pixels,"voxel_word":painted.voxels.decode_u32(index),"voxel_sha256":_sha256(painted.voxels),"field_peak_byte":painted.peak,"droplets":painted.droplets})
	var file := FileAccess.open(destination+"/probe.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(results,"\t"))
	file.close()
	print("ORDINARY_LIQUID_PROBE_CHECKS %d FAILURES %d"%[checks,failures])
	quit(0 if failures==0 else 1)

func _sha256(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()

func _rt_probe_snapshot(cells: Array) -> void:
	sim._rt_flush_render_preparation()
	var rd: RenderingDevice = sim._rd
	var fields := rd.texture_get_data(sim._density_rid,0)
	var peak := 0
	for p in cells: peak = maxi(peak,fields[VoxelCodec.index(p.x,p.y,p.z)*4])
	var counts := rd.buffer_get_data(sim._splat_counter)
	snapshot_ready.emit.call_deferred({"voxels":rd.texture_get_data(sim._grid_rid,0),"droplets":counts.decode_u32(8),"eligible":counts.decode_u32(23*4),"overflow":rd.texture_get_data(sim._physical_overflow_rid,0)[2],"peak":peak})

func _slab_probes(image: Image,cells: Array,amount: int,cell_size: float) -> Dictionary:
	var tested := 0
	var wrong := 0
	var max_error := 0.0
	var positive := 0
	for y in range(4,316,4):
		for x in range(4,316,4):
			var pixel := Vector2(x+0.5,y+0.5)
			var origin := camera.project_ray_origin(pixel)
			var direction := camera.project_ray_normal(pixel)
			var expected := 0.0
			for p in cells:
				var lower := (Vector3(p)-Vector3.ONE*VoxelCodec.GRID*0.5)*cell_size
				var upper := lower+Vector3(1,minf(float(amount)/200,1),1)*cell_size
				var interval := _interval(origin,direction,lower,upper)
				expected += maxf(interval.y-maxf(interval.x,0),0)/cell_size*maxf(float(amount)/200,1)
			if expected>0 and expected<0.001: continue
			var actual := image.get_pixel(x,y).srgb_to_linear().r*4
			var error := absf(actual-expected)
			if expected>0: positive += 1
			if error>0.035 or (expected>=0.003 and actual==0): wrong += 1
			max_error = maxf(max_error,error)
			tested += 1
	return {"samples":tested,"positive":positive,"wrong":wrong,"max_error_cells":max_error,"tolerance_cells":0.035,"missing_gate":"expected>=0.003 requires nonzero optical length"}
