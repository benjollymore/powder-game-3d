extends SceneTree
## Palette 16 -> 32 must be a pure capacity change. Every spatial shader is
## rendered A/B against its immutable pre-change copy on the same frozen
## physical state and the PNG bytes must be identical. No solver rule, byte
## format or authored scenario changes here.
## godot --path . --always-on-top --disable-vsync -s res://tests/milestone/palette_capture_gpu.gd -- grid=128
const ROLES := {
	"Mesh": ["res://tests/milestone/fixtures/voxel_opaque_palette16_baseline.gdshader", "res://shaders/spatial/voxel_opaque.gdshader"],
	"VolumeMesh": ["res://tests/milestone/fixtures/voxel_volume_palette16_baseline.gdshader", "res://shaders/spatial/voxel_volume.gdshader"],
	"Splats": ["res://tests/milestone/fixtures/splat_palette16_baseline.gdshader", "res://shaders/spatial/splat.gdshader"],
	"Leaves": ["res://tests/milestone/fixtures/leaf_palette16_baseline.gdshader", "res://shaders/spatial/leaf.gdshader"],
	"Droplets": ["res://tests/milestone/fixtures/droplet_palette16_baseline.gdshader", "res://shaders/spatial/droplet.gdshader"],
}
## Scenario, ticks to advance before freezing, camera position in grid units.
const SCENES := [
	{"name": "Demo", "ticks": 0, "eye": Vector3(150, 110, 150)},
	{"name": "Dam break", "ticks": 40, "eye": Vector3(140, 90, 160)},
	{"name": "Forest fire", "ticks": 40, "eye": Vector3(150, 100, 150)},
]
var sim: Node3D
var camera: Camera3D
var checks := 0
var failures := 0
var out_dir := "res://docs/milestone/palette-evidence"

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			out_dir = argument.trim_prefix("output_dir=")
	create_timer(110).timeout.connect(func(): push_error("Palette capture timeout"); quit(2))
	call_deferred("_run")

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error("FAIL: " + message)
	else:
		print("ok: " + message)

func _read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func _world(cell: Vector3) -> Vector3:
	var size: float = sim.world_size()
	return (cell / float(VoxelCodec.GRID) - Vector3.ONE * 0.5) * size

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(320, 320)
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
	world.environment.background_color = Color("202b38")
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.6
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	var to_sun := Vector3(0.4, 1.0, 0.3).normalized()
	sun.shadow_enabled = false
	stage.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP)
	sim.set_param("light_dir", to_sun)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	for i in 20:
		await process_frame
	# The 16-entry table array is what every current caller uploads; the new
	# shaders must zero-fill the tail and render identically.
	_check(Elements.palette().size() <= MaterialLibrary.SHADER_SLOTS, "element palette fits the shader slots")
	var s := float(VoxelCodec.GRID) / 128.0
	for scene in SCENES:
		sim.load_scenario(scene.name)
		for i in 6:
			await process_frame
		if scene.ticks > 0:
			sim.request_ticks(scene.ticks)
		var frozen: PackedByteArray = await _read()
		camera.position = _world(Vector3(scene.eye) * s)
		camera.look_at(_world(Vector3(64, 40, 64) * s), Vector3.UP)
		var images := {}
		for variant in [0, 1]:
			for node_name in ROLES:
				var material: ShaderMaterial = sim.get_node(node_name).material_override
				material.shader = load(ROLES[node_name][variant])
			sim.set_param("palette", Elements.palette())
			for i in 12:
				await process_frame
			await RenderingServer.frame_post_draw
			var img := root.get_texture().get_image()
			images[variant] = img
			var label := "baseline" if variant == 0 else "palette32"
			_check(img.save_png(out_dir + "/%s-%s.png" % [scene.name.to_lower().replace(" ", "-"), label]) == OK, "%s %s capture saved" % [scene.name, label])
		var a: PackedByteArray = images[0].get_data()
		var b: PackedByteArray = images[1].get_data()
		var lit := 0
		for i in range(0, a.size(), 4):
			if a[i] != 0x20 or a[i + 1] != 0x2b or a[i + 2] != 0x38:
				lit += 1
		_check(lit > 2000, "%s capture shows substantial content (%d non-background pixels)" % [scene.name, lit])
		_check(a == b, "%s renders byte-identically with palette 32" % scene.name)
		var after: PackedByteArray = await _read()
		_check(after == frozen, "%s physical bytes unchanged across captures" % scene.name)
	# Every per-id uniform accepts a padded 32-entry array without changing output.
	var padded: PackedColorArray = MaterialLibrary.padded(Elements.palette())
	_check(padded.size() == MaterialLibrary.SHADER_SLOTS and padded[MaterialLibrary.SHADER_SLOTS - 1] == Color(0, 0, 0, 0), "padded palette has a zero tail")
	print("PALETTE_CHECKS %d FAILURES %d" % [checks, failures])
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if failures else 0)
