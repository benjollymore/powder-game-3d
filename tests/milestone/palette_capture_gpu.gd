extends SceneTree
## Palette 16 -> 32 and the thermal-glow scaffold must be pure capacity
## changes while glow is off. Every spatial shader is rendered A/B against its
## immutable pre-change copy on the same frozen physical state and the PNG
## bytes must be identical, including with the thermal texture bound but
## thermal_glow=false. Glow on with a hot cell must change pixels, and the new
## material rows (when present) must render with a readable default look.
## No solver rule, byte format or authored scenario changes here.
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

func _lit(img: Image) -> int:
	var a := img.get_data()
	var lit := 0
	for i in range(0, a.size(), 4):
		if a[i] != 0x20 or a[i + 1] != 0x2b or a[i + 2] != 0x38:
			lit += 1
	return lit

func _diff(a_img: Image, b_img: Image) -> int:
	var a := a_img.get_data()
	var b := b_img.get_data()
	var changed := 0
	for i in range(0, mini(a.size(), b.size()), 4):
		if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2]:
			changed += 1
	return changed

## Swap every role to baseline (0) or current (1) shaders, optionally bind the
## thermal texture and set the glow toggle, then capture one settled frame.
func _capture(variant: int, glow: bool, bind_thermal: bool) -> Image:
	for node_name in ROLES:
		var material: ShaderMaterial = sim.get_node(node_name).material_override
		material.shader = load(ROLES[node_name][variant])
	sim.set_param("palette", Elements.palette())
	if variant == 1:
		if bind_thermal:
			sim.set_param("thermal", sim.thermal_texture)
		sim.set_param("thermal_glow", glow)
	for i in 12:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()

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
		var lit := _lit(images[0])
		_check(lit > 2000, "%s capture shows substantial content (%d non-background pixels)" % [scene.name, lit])
		_check(a == b, "%s renders byte-identically with palette 32" % scene.name)
		var after: PackedByteArray = await _read()
		_check(after == frozen, "%s physical bytes unchanged across captures" % scene.name)
	# Glow scaffold: bound thermal texture with thermal_glow=false is identical to
	# the pre-thermal shaders; enabled on a hot block it must change pixels.
	var has_thermal: bool = "thermal_texture" in sim and sim.thermal_texture != null
	var demo := SCENES[0]
	sim.load_scenario(demo.name)
	for i in 6:
		await process_frame
	var frozen_demo: PackedByteArray = await _read()
	camera.position = _world(Vector3(demo.eye) * s)
	camera.look_at(_world(Vector3(64, 40, 64) * s), Vector3.UP)
	var base_img := await _capture(0, false, has_thermal)
	var off_img := await _capture(1, false, has_thermal)
	_check(base_img.get_data() == off_img.get_data(), "thermal bound (%s) with thermal_glow=false renders byte-identically" % has_thermal)
	_check(off_img.save_png(out_dir + "/demo-thermal-off.png") == OK, "thermal-off capture saved")
	if has_thermal:
		# Heat the whole world to 1400 K on the thermal layer only; voxels unchanged.
		var n := VoxelCodec.GRID
		var hot := PackedFloat32Array()
		hot.resize(n * n * n * 2)
		for i in range(0, hot.size(), 2):
			hot[i] = 1400.0
		sim.upload(frozen_demo, hot.to_byte_array())
		for i in 6:
			await process_frame
		var on_img := await _capture(1, true, true)
		_check(on_img.save_png(out_dir + "/demo-thermal-on.png") == OK, "thermal-on capture saved")
		var d := _diff(off_img, on_img)
		_check(d > 500, "thermal glow at 1400 K changes the picture (%d pixels)" % d)
		var after_hot: PackedByteArray = await _read()
		_check(after_hot == frozen_demo, "thermal glow leaves physical bytes unchanged")
		sim.set_param("thermal_glow", false)
	else:
		print("note: VoxelSim has no thermal_texture yet; glow-on case skipped")
	# New material rows: render once they exist so their default look is reviewable.
	var wanted := ["ICE", "GLASS", "LAVA", "STONE", "METAL"]
	var present: Array = []
	for name in wanted:
		if Elements.Id.has(name):
			present.append(name)
	if present.is_empty():
		print("note: no heat-milestone element rows present; material fixture skipped")
	else:
		var n := VoxelCodec.GRID
		var data := WorldBuilder.empty()
		var k := 0
		for name in present:
			var id: int = Elements.Id[name]
			var x0 := int(float(n) * (0.1 + 0.16 * k))
			for z in range(n * 3 / 8, n * 5 / 8):
				for y in range(n / 4, n * 7 / 16):
					for x in range(x0, x0 + n / 8):
						data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, (x * 7 + z * 13) % 256, Elements.default_amount(id))
			k += 1
		var bytes := data.to_byte_array()
		sim.upload(bytes)
		for i in 6:
			await process_frame
		camera.position = _world(Vector3(64, 70, 150) * s)
		camera.look_at(_world(Vector3(64, 40, 64) * s), Vector3.UP)
		var img := await _capture(1, has_thermal, has_thermal)
		_check(img.save_png(out_dir + "/materials-%s.png" % "-".join(present).to_lower()) == OK, "material fixture capture saved for %s" % ", ".join(present))
		_check(_lit(img) > 2000, "material fixture shows substantial content")
		var after_mat: PackedByteArray = await _read()
		_check(after_mat == bytes, "material fixture physical bytes unchanged")
	# Every per-id uniform accepts a padded 32-entry array without changing output.
	var padded: PackedColorArray = MaterialLibrary.padded(Elements.palette())
	_check(padded.size() == MaterialLibrary.SHADER_SLOTS and padded[MaterialLibrary.SHADER_SLOTS - 1] == Color(0, 0, 0, 0), "padded palette has a zero tail")
	print("PALETTE_CHECKS %d FAILURES %d" % [checks, failures])
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(1 if failures else 0)
