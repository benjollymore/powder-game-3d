extends SceneTree
## Read-only overflow reproduction, not a passing fallback regression.
signal snapshot_ready(state: Dictionary)
const OUT := "res://docs/milestone/material-capacity-evidence"
var sim: Node3D
var camera: Camera3D
var checks := 0
var failures := 0

func _initialize() -> void:
	root.get_node("TimeController").paused = true
	create_timer(120).timeout.connect(func(): push_error("Capacity probe timeout"); quit(2))
	call_deferred("_run")

func _run() -> void:
	root.size = Vector2i(900,700)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	var stage := Node3D.new()
	root.add_child(stage)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.fov = 45
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_energy = 1
	stage.add_child(world)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var rows: Array[Dictionary] = []
	var cases := [
		{"name":"small-grains","layer":0,"element":Elements.Id.SAND,"amount":0,"flags":6,"count":100,"capacity":16},
		{"name":"small-droplets","layer":2,"element":Elements.Id.WATER,"amount":50,"flags":1,"count":100,"capacity":16},
		{"name":"small-leaves","layer":1,"element":Elements.Id.PLANT,"amount":0,"flags":0,"count":100,"capacity":16},
		{"name":"actual-grain-capacity","layer":0,"element":Elements.Id.SAND,"amount":0,"flags":6,"count":131328,"capacity":131072},
		{"name":"actual-droplet-capacity","layer":2,"element":Elements.Id.WATER,"amount":50,"flags":1,"count":65792,"capacity":65536}]
	for c in cases:
		var fixture := _world(c)
		var bytes: PackedByteArray = fixture.bytes
		var variants: Array = [c.capacity,c.count] if c.count==100 else [c.capacity]
		var capped_image: Image
		for capacity in variants:
			sim = load("res://scenes/sim_volume.tscn").instantiate()
			sim.listen_to_time_controller = false
			sim.current_scenario = "Empty"
			sim.fx_enabled = false
			sim.get_node(["Splats","Leaves","Droplets"][c.layer]).capacity = capacity
			stage.add_child(sim)
			camera.position = Vector3(0.35,0.8,0.8)*sim.world_size()
			camera.look_at(Vector3.ZERO)
			for i in 20:
				await process_frame
			sim.upload(bytes)
			for i in 20:
				await process_frame
			RenderingServer.call_on_render_thread(_rt_snapshot.bind(c.layer))
			var state: Dictionary = await snapshot_ready
			_check(state.voxels==bytes,c.name+" exact physical bytes unchanged")
			var represented := {}
			var invalid := 0
			var wrong_cells := 0
			for i in mini(state.counter,capacity):
				var offset: int = i*64
				var origin := Vector3(state.instances.decode_float(offset+12),state.instances.decode_float(offset+28),state.instances.decode_float(offset+44))
				if not origin.is_finite():
					invalid += 1
					continue
				var cell := Vector3i(((origin+Vector3.ONE*0.5)*VoxelCodec.GRID).floor())
				if not fixture.cells.has(cell):
					wrong_cells += 1
				represented[cell] = true
			var channel := 0 if c.layer==2 else 1
			var peak := 0
			for i in VoxelCodec.GRID*VoxelCodec.GRID*VoxelCodec.GRID:
				peak = maxi(peak,state.fields[i*4+channel])
			var row := {"case":c.name,"capacity":capacity,"physical_candidates":c.count,"counter":state.counter,"unique_instance_cells":represented.size(),"nonfinite_records":invalid,"field_peak_byte":peak,"missing_instance_cells":c.count-represented.size()}
			rows.append(row)
			print(JSON.stringify(row))
			_check(invalid==0,c.name+" finite instance origins")
			_check(wrong_cells==0,c.name+" every instance belongs to a physical cell")
			_check(represented.size()==mini(capacity,c.count),c.name+" emitted cells reach allocated capacity")
			_check(peak<128,c.name+" no fallback isosurface exists anywhere")
			if capacity<c.count:
				_check(row.missing_instance_cells>0,c.name+" reproduces unrepresented physical cells")
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var name: String = c.name + ("-capped" if capacity<c.count else "-enough-capacity")
			_check(image.save_png(OUT+"/"+name+".png")==OK,"capture "+name)
			if capacity<c.count:
				capped_image = image
			elif capped_image!=null:
				_check(capped_image.get_data()!=image.get_data(),c.name+" more physical instances visibly change image")
			sim.queue_free()
			for i in 10:
				await process_frame
	var file := FileAccess.open(OUT+"/probe.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	print("CAPACITY_PROBE_CHECKS %d FAILURES %d"%[checks,failures])
	quit(0 if failures==0 else 1)

func _world(c: Dictionary) -> Dictionary:
	var data := WorldBuilder.empty()
	var cells := {}
	if c.count==100:
		for z in 10:
			for x in 10:
				cells[Vector3i(44+x*4,64,44+z*4)] = true
	else:
		for z in range(2,VoxelCodec.GRID-2,2):
			for y in range(2,VoxelCodec.GRID-2,2):
				for x in range(2,VoxelCodec.GRID-2,2):
					if cells.size()<c.count:
						cells[Vector3i(x,y,z)] = true
	for p in cells:
		data[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(c.element,WorldBuilder.seed_at(p.x,p.y,p.z),c.amount) | (int(c.flags)<<24)
	assert(cells.size()==c.count)
	return {"bytes":data.to_byte_array(),"cells":cells}

func _rt_snapshot(layer: int) -> void:
	sim._rt_flush_render_preparation()
	var rd: RenderingDevice = sim._rd
	var counter := rd.buffer_get_data(sim._splat_counter).decode_u32(layer*4)
	snapshot_ready.emit.call_deferred({"counter":counter,"instances":rd.buffer_get_data(sim._layer_buffer[layer]),"fields":rd.texture_get_data(sim._density_rid,0),"voxels":rd.texture_get_data(sim._grid_rid,0)})

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	if not message.is_empty():
		print(("ok: " if ok else "FAIL: ")+message)
