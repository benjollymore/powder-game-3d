extends SceneTree
## Matched frozen materials/sections, retaining the production physical layers.
## godot --path . --always-on-top --disable-vsync -s res://tools/milestone/capture_presentation.gd -- grid=128
const Presentation := preload("res://scripts/render/editor_presentation.gd")
const OUT := "res://docs/milestone/presentation-evidence"
var sim: Node3D
var camera: Camera3D
var stage: Node3D
var label: Label

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(1600,900)
	stage = Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	stage.add_child(sim)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.fov = 55.0
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	stage.add_child(world)
	Presentation.apply(sim, world, stage)
	var overlay := CanvasLayer.new()
	stage.add_child(overlay)
	label = Label.new()
	label.position = Vector2(24,24)
	label.add_theme_font_size_override("font_size", 21)
	overlay.add_child(label)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for i in 30:
		await process_frame
	var bytes := _build()
	sim.upload(bytes)
	var hash_before := _hash(bytes)
	var cases: Array[Dictionary] = [
		{"name":"oblique", "camera":Vector3(0.9,0.55,1.0), "section":false, "axis":2, "depth":64},
		{"name":"reverse", "camera":Vector3(-0.9,0.5,-0.8), "section":false, "axis":2, "depth":64},
		{"name":"section-z", "camera":Vector3(0.8,0.5,1.0), "section":true, "axis":2, "depth":64},
		{"name":"section-x", "camera":Vector3(1.0,0.5,0.8), "section":true, "axis":0, "depth":64}
	]
	for c in cases:
		camera.position = c.camera * sim.world_size()
		camera.look_at(Vector3(0,-0.08,0) * sim.world_size())
		sim.set_param("section_enabled", c.section)
		sim.set_param("section_axis", c.axis)
		sim.set_param("section_cell", int(float(c.depth) / 128.0 * VoxelCodec.GRID) - 1)
		for baseline in [true, false]:
			_swap_shaders(baseline)
			label.text = "FROZEN MATERIAL / SECTION STUDY\n%s  ·  %s  ·  %d³ unchanged physical state" % [c.name, "Before surface fixes" if baseline else "After surface fixes", VoxelCodec.GRID]
			for i in 45:
				await process_frame
			await RenderingServer.frame_post_draw
			var path: String = OUT + "/" + c.name + ("-baseline.png" if baseline else "-fixed.png")
			assert(root.get_texture().get_image().save_png(path) == OK)
			print("CAPTURE ", path)
		if c.name in ["oblique", "section-z"]:
			_original_editor_look(world)
			label.text = "FROZEN MATERIAL / SECTION STUDY\n%s  ·  Original editor lighting/material settings  ·  same fixed shader" % c.name
			for i in 30:
				await process_frame
			await RenderingServer.frame_post_draw
			var path: String = OUT + "/" + c.name + "-original-editor-style.png"
			assert(root.get_texture().get_image().save_png(path) == OK)
			print("CAPTURE ", path)
			Presentation.apply(sim, world, stage)
	var result: Array[PackedByteArray] = []
	sim.request_readback(func(data: PackedByteArray): result.append(data))
	var deadline := Time.get_ticks_msec() + 15000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	assert(not result.is_empty(), "GPU readback timeout")
	assert(result[0] == bytes, "Presentation changed the physical world")
	print("PRESENTATION_STATE_UNCHANGED ", hash_before, " grid=", VoxelCodec.GRID)
	quit()

func _original_editor_look(world: WorldEnvironment) -> void:
	var env := world.environment
	env.background_color = Color("18222e")
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.get_node("EditorSun").visible = false
	sim.set_param("palette", Elements.palette())
	sim.set_param("sky_color", Color(0.74,0.79,0.84))
	sim.set_param("ground_color", Color(0.82,0.84,0.86))
	sim.set_param("sun_color", Color(1.0,0.96,0.9))
	for key in ["detail_strength", "ao_strength", "foam_strength", "caustic_strength"]:
		sim.set_param(key,1.0)
	sim.set_param("refraction",0.045)
	sim.set_param("absorb",Vector3(0.10,0.045,0.02))
	sim.set_param("scatter",0.05)
	sim.set_param("liquid_specular",0.7)

func _swap_shaders(baseline: bool) -> void:
	var materials := {"Mesh":"voxel_opaque", "Splats":"splat", "Droplets":"droplet", "Leaves":"leaf", "Fx":"fx"}
	for child in materials:
		var material: ShaderMaterial = sim.get_node(child).material_override
		var name: String = materials[child]
		material.shader = load("res://tests/milestone/fixtures/" + name + "_baseline.gdshader") if baseline else load("res://shaders/spatial/" + name + ".gdshader")

func _build() -> PackedByteArray:
	var d := WorldBuilder.empty()
	_box(d, Vector3i(4,2,4), Vector3i(124,6,124), Elements.Id.WALL)
	WorldBuilder.fill_bowl(d, _v(Vector3i(30,6,30)), _v(Vector3i(96,70,96)), maxi(1,VoxelCodec.GRID / 64))
	_box(d, Vector3i(32,8,32), Vector3i(94,43,94), Elements.Id.WATER)
	_box(d, Vector3i(40,8,42), Vector3i(62,24,74), Elements.Id.WALL)
	_box(d, Vector3i(40,24,42), Vector3i(50,32,74), Elements.Id.WALL)
	_box(d, Vector3i(70,43,40), Vector3i(88,46,58), Elements.Id.OIL)
	# A one-cell-wide screen tests visual construction scale alongside bulk materials.
	_box(d, Vector3i(12,6,12), Vector3i(13,42,28), Elements.Id.WALL)
	var g := float(VoxelCodec.GRID) / 128.0
	for y in range(int(6*g),int(33*g)):
		var radius := (33.0*g - y)*0.46
		for z in range(int(48*g),int(76*g)):
			for x in range(int(98*g),int(124*g)):
				if Vector2(x-111*g,z-62*g).length() < radius:
					d[VoxelCodec.index(x,y,z)] = VoxelCodec.encode(Elements.Id.SAND,WorldBuilder.seed_at(x,y,z))
	WorldBuilder.fill_sphere(d, Vector3(16,15,100)*g, 8*g, Elements.Id.PLANT)
	WorldBuilder.fill_sphere(d, Vector3(16,76,42)*g, 9*g, Elements.Id.STEAM)
	for y in range(46,72,2):
		var p := _v(Vector3i(111,y,62))
		d[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(Elements.Id.SAND,y*3) | (6<<24)
	for y in range(78,106,2):
		var p := _v(Vector3i(63,y,63))
		d[VoxelCodec.index(p.x,p.y,p.z)] = VoxelCodec.encode(Elements.Id.WATER,y*3,150) | (1<<24)
	return d.to_byte_array()

func _v(v: Vector3i) -> Vector3i:
	return Vector3i(Vector3(v)*float(VoxelCodec.GRID)/128.0)

func _box(d: PackedInt32Array, lo: Vector3i, hi: Vector3i, id: int) -> void:
	WorldBuilder.fill_box(d,_v(lo),_v(hi),id)

func _hash(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()
