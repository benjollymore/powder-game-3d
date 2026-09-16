extends SceneTree
## Plant growing through a body of water over a long session. PLANT + WATER ->
## PLANT + PLANT at p=0.0015 per adjacent pair per tick, and every plant cell
## with an air or gas face grows leaf cards, so a creeping growth front lays
## sprites on a cell-aligned grid. Grazing capture, leaf layer on and off.
signal ready_result(value: Variant)
var sim: Node3D
var OUT := "res://docs/milestone/lattice-evidence/growth"
var ticks := 6000
var water_depth := 10

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): OUT = arg.trim_prefix("output_dir=")
		elif arg.begins_with("ticks="): ticks = int(arg.trim_prefix("ticks="))
		elif arg.begins_with("depth="): water_depth = int(arg.trim_prefix("depth="))
	root.get_node("TimeController").paused = true
	create_timer(1500).timeout.connect(func(): push_error("Lattice growth timeout"); quit(2))
	call_deferred("_run")


func _read() -> PackedByteArray:
	RenderingServer.call_on_render_thread(func(): ready_result.emit.call_deferred(sim._rd.texture_get_data(sim._grid_rid, 0)))
	return await ready_result


func _capture(name: String) -> void:
	for i in 5: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OUT + "/" + name + ".png")


func _census(bytes: PackedByteArray) -> Dictionary:
	var n := VoxelCodec.GRID
	var plant := 0
	var water := 0
	for i in range(0, bytes.size(), 4):
		var id := bytes[i]
		if id == Elements.Id.PLANT: plant += 1
		elif id == Elements.Id.WATER: water += 1
	return {"plant": plant, "water": water}


func _run() -> void:
	root.size = Vector2i(1060, 560)
	root.scaling_3d_scale = 1.0
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	var stage := Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	stage.add_child(sim)
	var camera := Camera3D.new()
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color(0.67, 0.74, 0.84)
	world.environment.ambient_light_energy = 1.0
	stage.add_child(world)
	for i in 24: await process_frame

	var n := VoxelCodec.GRID
	# The real editor presentation: filmic tonemap, ambient 0.65, a sun, and the
	# palette overrides. Without the sun the leaf cards are ambient-only and read
	# green; this is what the reported frame actually had.
	var EditorPresentation := load("res://scripts/render/editor_presentation.gd")
	EditorPresentation.apply(sim, world, stage)

	# Walled tank, water in it, a plant seed wall along one edge.
	var floor_top := 8
	var data := WorldBuilder.empty()
	for z in range(0, n):
		for x in range(0, n):
			for y in range(0, floor_top):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WALL, 11, 0)
	for z in range(4, n - 4):
		for x in range(4, n - 4):
			for y in range(floor_top, floor_top + water_depth):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.WATER, 17, 200)
	# Seed: a plant slab along the far edge, touching the water.
	for z in range(4, 12):
		for x in range(4, n - 4):
			for y in range(floor_top, floor_top + water_depth):
				data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.PLANT, 11, 0)
	sim.upload(data.to_byte_array())
	for i in 12: await process_frame

	var world_size: float = sim.world_size()
	var cell: float = world_size / float(n)
	var surf := (floor_top + water_depth) * cell - world_size * 0.5
	# Grazing, close: the view in the report.
	# Close to the growth front, looking down the water toward the plant, so the
	# plant band fills the upper frame and the water surface the lower, as reported.
	camera.position = Vector3(0.0, surf + 13.0 * cell, -4.0 * cell)
	camera.look_at(Vector3(0.0, surf + 2.0 * cell, -52.0 * cell))
	camera.near = 0.001
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))

	var summary := {"grid": n, "ticks": ticks, "water_depth": water_depth, "census": []}
	summary.census.append(_census(await _read()))
	await _capture("t0000")
	var marks := [500, 1500, 3000, 4500, 6000, 9000, 12000]
	var done := 0
	while done < ticks:
		sim.request_ticks(1)
		await process_frame
		done += 1
		if done in marks:
			await _capture("t%04d" % done)
			summary.census.append(_census(await _read()))
			print("tick %d census %s" % [done, JSON.stringify(summary.census[-1])])

	# Leaf layer on versus off on the final state.
	await _capture("final-leaves-on")
	sim.get_node("Leaves").visible = false
	await _capture("final-leaves-off")
	sim.get_node("Leaves").visible = true
	sim.get_node("Droplets").visible = false
	await _capture("final-droplets-off")
	sim.get_node("Droplets").visible = true
	sim.set_param("foam_strength", 0.0)
	await _capture("final-no-foam")
	sim.set_param("foam_strength", 1.0)

	var file := FileAccess.open(OUT + "/growth.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "\t"))
	file.close()
	print("LATTICE_GROWTH grid=%d ticks=%d final=%s" % [n, ticks, JSON.stringify(summary.census[-1])])
	quit(0)
