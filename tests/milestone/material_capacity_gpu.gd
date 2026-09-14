extends SceneTree
## Exact eligibility, whole-layer fallback, recovery, and legacy under-capacity regression.
signal snapshot_ready(state: Dictionary)
const OUT := "res://docs/milestone/material-capacity-evidence/fixed"
var out_dir := OUT
var sim: Node3D
var camera: Camera3D
var checks := 0
var failures := 0

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): out_dir = arg.trim_prefix("output_dir=")
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
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.7
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50,-25,0)
	sun.light_energy = 1.5
	stage.add_child(sun)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var rows: Array[Dictionary] = []
	var cases := [
		{"name":"small-grains","layer":0,"element":Elements.Id.SAND,"amount":0,"flags":6,"count":100,"capacity":16},
		{"name":"small-droplets","layer":2,"element":Elements.Id.WATER,"amount":50,"flags":1,"count":100,"capacity":16},
		{"name":"small-leaves","layer":1,"element":Elements.Id.PLANT,"amount":0,"flags":0,"count":100,"capacity":16},
		{"name":"actual-grain-capacity","layer":0,"element":Elements.Id.SAND,"amount":0,"flags":6,"count":131328,"capacity":131072},
		{"name":"actual-droplet-capacity","layer":2,"element":Elements.Id.WATER,"amount":50,"flags":1,"count":65792,"capacity":65536},
		{"name":"actual-leaf-capacity","layer":1,"element":Elements.Id.PLANT,"amount":0,"flags":0,"count":262400,"capacity":262144}]
	if OS.get_cmdline_user_args().has("visual_only=1"):
		cases = cases.slice(0,3)
	for c in cases:
		var fixture := _world(c)
		var bytes: PackedByteArray = fixture.bytes
		var variants: Array = [c.capacity,c.count,c.count+1] if c.count==100 else [c.capacity]
		var capped_image: Image
		for capacity in variants:
			sim = load("res://scenes/sim_volume.tscn").instantiate()
			sim.listen_to_time_controller = false
			sim.current_scenario = "Empty"
			sim.fx_enabled = false
			sim.get_node(["Splats","Leaves","Droplets"][c.layer]).capacity = capacity
			stage.add_child(sim)
			sim.set_param("proxy_surface_reflection",not OS.get_cmdline_user_args().has("no_proxy_reflection=1"))
			camera.position = (Vector3(0.23,0.38,0.42) if c.count==100 else Vector3(0.35,0.8,0.8))*sim.world_size()
			camera.look_at(Vector3.ZERO)
			for i in 20:
				await process_frame
			sim.upload(bytes)
			for i in 20:
				await process_frame
			RenderingServer.call_on_render_thread(_rt_snapshot.bind(c.layer))
			var state: Dictionary = await snapshot_ready
			_check(state.voxels==bytes,c.name+" exact physical bytes unchanged")
			var fallback: bool = capacity < c.count
			_check(state.eligible==c.count,c.name+" exact eligibility independent of cap")
			_check(state.overflow[c.layer]==(255 if fallback else 0),c.name+" whole-layer overflow flag")
			var expected := PackedByteArray()
			expected.resize(state.instances.size())
			var represented := _records(state.instances,mini(capacity,c.count))
			if fallback:
				_check(state.instances==expected,c.name+" every partial sprite record suppressed")
				if c.layer!=2:
					var all_covered := true
					for p in fixture.cells:
						all_covered = all_covered and state.fields[VoxelCodec.index(p.x,p.y,p.z)*4+1]==255
					_check(all_covered,c.name+" every physical cell has an opaque field center")
			else:
				_check(represented.size()==c.count,c.name+" every under-capacity physical instance represented")
				RenderingServer.call_on_render_thread(_rt_legacy_snapshot.bind(c.layer))
				var legacy: Dictionary = await snapshot_ready
				_check(state.fields==legacy.fields,c.name+" exact legacy density and foam bytes")
				_check(represented==_records(legacy.instances,c.count),c.name+" exact legacy records, ignoring atomic ordering")
				_check(state.voxels==legacy.voxels and state.air==legacy.air,c.name+" legacy comparison preserves voxels and all seven air textures")
				# Restore the candidate after the independent legacy pass.
				sim.upload(bytes)
				for i in 3: await process_frame
			var row := {"case":c.name,"capacity":capacity,"physical_candidates":c.count,"voxel_sha256":_sha256(bytes),"eligible":state.eligible,"allocation_counter":state.counter,"fallback":fallback}
			rows.append(row)
			print(JSON.stringify(row))
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image()
			var name: String = c.name + ("-capped" if capacity<c.count else "-enough-capacity")
			_check(image.save_png(out_dir+"/"+name+".png")==OK,"capture "+name)
			if capacity<c.count:
				capped_image = image
			elif capped_image!=null:
				_check(capped_image.get_data()!=image.get_data(),c.name+" fallback visibly differs from physical sprites")
			if fallback:
				# A zero-time repeated preparation cannot select different winners.
				RenderingServer.call_on_render_thread(_rt_repeat.bind(c.layer))
				var repeated: Dictionary = await snapshot_ready
				_check(repeated.fields==state.fields and repeated.instances==state.instances and repeated.overflow==state.overflow,c.name+" deterministic repeated fallback")
				_check(repeated.voxels==state.voxels and repeated.air==state.air,c.name+" preparation preserves physical voxels and all seven air textures")
				var recovered := WorldBuilder.empty()
				var first: Vector3i = fixture.cells.keys()[0]
				recovered[VoxelCodec.index(first.x,first.y,first.z)] = VoxelCodec.encode(c.element,17,c.amount)|(int(c.flags)<<24)
				sim.upload(recovered.to_byte_array())
				for i in 3: await process_frame
				RenderingServer.call_on_render_thread(_rt_snapshot.bind(c.layer))
				var recovery: Dictionary = await snapshot_ready
				_check(recovery.eligible==1 and recovery.overflow[c.layer]==0 and recovery.counter==1,c.name+" recovers to exact sprite path below cap")
				sim.upload(WorldBuilder.empty().to_byte_array())
				for i in 3: await process_frame
				RenderingServer.call_on_render_thread(_rt_snapshot.bind(c.layer))
				var empty: Dictionary = await snapshot_ready
				_check(empty.eligible==0 and empty.overflow[c.layer]==0 and empty.instances==expected,c.name+" reset clears stale fallback and sprites")
			sim.queue_free()
			for i in 10:
				await process_frame
	var file := FileAccess.open(out_dir+("/visual.json" if OS.get_cmdline_user_args().has("visual_only=1") else "/regression.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	print("CAPACITY_FALLBACK_CHECKS %d FAILURES %d"%[checks,failures])
	quit(0 if failures==0 else 1)

func _world(c: Dictionary) -> Dictionary:
	var data := WorldBuilder.empty()
	var cells := {}
	if c.count==100:
		for z in 10:
			for x in 10:
				cells[Vector3i(44+x*4,64,44+z*4)] = true
	elif c.layer==1:
		for z in range(2,VoxelCodec.GRID-2):
			for y in range(2,VoxelCodec.GRID-2):
				for x in range(2,VoxelCodec.GRID-2):
					if (x+y+z)%2==0 and cells.size()<c.count:
						cells[Vector3i(x,y,z)] = true
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

func _sha256(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()

func _records(bytes: PackedByteArray, count: int) -> Dictionary:
	var result := {}
	for i in count:
		var offset := i*64
		var origin := Vector3(bytes.decode_float(offset+12),bytes.decode_float(offset+28),bytes.decode_float(offset+44))
		var cell := Vector3i(((origin+Vector3.ONE*0.5)*VoxelCodec.GRID).floor())
		result[cell] = bytes.slice(offset,offset+64)
	return result

func _rt_snapshot(layer: int) -> void:
	sim._rt_flush_render_preparation()
	var rd: RenderingDevice = sim._rd
	var counters := rd.buffer_get_data(sim._splat_counter)
	var air: Array[PackedByteArray] = []
	for rid in [sim._air_vel[0],sim._air_vel[1],sim._air_pres[0],sim._air_pres[1],sim._air_div,sim._air_occ,sim._air_src]:
		air.append(rd.texture_get_data(rid,0))
	snapshot_ready.emit.call_deferred({"counter":counters.decode_u32(layer*4),"eligible":counters.decode_u32((21+layer)*4),"overflow":rd.texture_get_data(sim._physical_overflow_rid,0),"instances":rd.buffer_get_data(sim._layer_buffer[layer]),"fields":rd.texture_get_data(sim._density_rid,0),"voxels":rd.texture_get_data(sim._grid_rid,0),"air":air})

func _rt_repeat(layer: int) -> void:
	sim._rt_occupancy_update()
	_rt_snapshot(layer)

func _rt_legacy_snapshot(layer: int) -> void:
	var rd: RenderingDevice = sim._rd
	var resources: Array[RID] = []
	for name in ["splat_emit","fields"]:
		var source := RDShaderSource.new()
		source.source_compute = FileAccess.get_file_as_string("res://tests/milestone/fixtures/"+name+"_capacity_baseline.txt").replace("#[compute]","")
		var spirv := rd.shader_compile_spirv_from_source(source)
		assert(spirv.compile_error_compute.is_empty(),spirv.compile_error_compute)
		var shader := rd.shader_create_from_spirv(spirv)
		var pipeline := rd.compute_pipeline_create(shader,sim._spec([VoxelCodec.GRID]))
		var uniforms: Array[RDUniform]
		var push: PackedByteArray
		if name=="splat_emit":
			uniforms = [sim._image_uniform(0),sim._image_uniform(1,sim._occ_rid),sim._buffer_uniform(2,sim._elements_buffer),sim._buffer_uniform(3,sim._splat_counter),sim._buffer_uniform(4,sim._layer_buffer[0]),sim._buffer_uniform(5,sim._layer_buffer[1]),sim._buffer_uniform(6,sim._layer_buffer[2]),sim._buffer_uniform(7,sim._fx_spawns)]
			rd.buffer_clear(sim._splat_counter,0,sim.COUNTER_BYTES)
			for i in 3: rd.buffer_clear(sim._layer_buffer[i],0,sim._layer_capacity[i]*64)
			push = PackedInt32Array([sim._layer_capacity[0],sim._layer_capacity[1],sim._layer_capacity[2],0,sim._frame,Elements.Id.STEAM,0,0]).to_byte_array()
		else:
			uniforms = [sim._image_uniform(0),sim._image_uniform(1,sim._fields_views[0]),sim._buffer_uniform(2,sim._elements_buffer)]
			push = PackedFloat32Array([0,0,0,0]).to_byte_array()
		var uniform_set := rd.uniform_set_create(uniforms,shader,0)
		var cl := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(cl,pipeline)
		rd.compute_list_bind_uniform_set(cl,uniform_set,0)
		rd.compute_list_set_push_constant(cl,push,push.size())
		rd.compute_list_dispatch(cl,VoxelCodec.GRID/8,VoxelCodec.GRID/8,VoxelCodec.GRID/8)
		rd.compute_list_end()
		resources.append_array([uniform_set,pipeline,shader])
	_rt_snapshot(layer)
	for rid in resources: rd.free_rid(rid)

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	if not message.is_empty():
		print(("ok: " if ok else "FAIL: ")+message)
