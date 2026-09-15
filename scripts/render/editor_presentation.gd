extends RefCounted
## Paint-first material presentation, independent of editing and physical state.
## Apply once after the sim/environment enter the tree. Keeps every physical
## representation and section uniform intact. The legacy scenario viewer is independent.

static func apply(sim: Node3D, world: WorldEnvironment, parent: Node3D) -> DirectionalLight3D:
	if world.environment == null:
		world.environment = Environment.new()
	var env := world.environment
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("202b38")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.67, 0.74, 0.84)
	env.ambient_light_energy = 0.65
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0
	env.fog_enabled = false
	env.glow_enabled = false
	env.ssao_enabled = false
	var sun := parent.get_node_or_null("EditorSun") as DirectionalLight3D
	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "EditorSun"
		parent.add_child(sun)
	# Use the direction already consumed by the sun-visibility field. Changing
	# camera/material appearance must not need a physical-state upload/rebuild.
	var to_sun: Vector3 = sim.sun_to.normalized()
	sun.look_at(sun.global_position - to_sun, Vector3.UP)
	sun.visible = true
	sun.light_color = Color(1.0, 0.96, 0.89)
	sun.light_energy = 1.0
	sun.shadow_enabled = false # shared voxel sun-visibility shades all sim passes
	sim.set_param("light_dir", to_sun)
	sim.set_param("sun_color", sun.light_color * sun.light_energy)
	sim.set_param("sky_color", Color(0.62, 0.70, 0.80))
	sim.set_param("ground_color", Color(0.30, 0.35, 0.41))
	# Palette alpha is self-illumination in the shaders, so every override
	# must keep alpha 0 (a Color literal defaults to alpha 1 and would make
	# walls, sand and water glow).
	var palette := Elements.palette()
	palette[Elements.Id.WALL] = Color(0.34, 0.40, 0.46, 0.0)
	palette[Elements.Id.SAND] = Color(0.87, 0.65, 0.31, 0.0)
	palette[Elements.Id.WATER] = Color(0.08, 0.37, 0.62, 0.0)
	if Elements.Id.has("ICE"):
		# LIGHT_COLOR carries a factor of pi, so a sun-facing face is lit about
		# 2.8x its albedo: the table's pale ice blows out to white under the
		# editor sun. A deep blue albedo keeps it readable next to steam and the
		# pale wall while still reading as ice.
		palette[Elements.Id.ICE] = Color(0.26, 0.44, 0.60, 0.0)
	sim.set_param("palette", palette)
	sim.set_param("detail_strength", 0.18)
	sim.set_param("ao_strength", 0.55)
	sim.set_param("refraction", 0.012)
	sim.set_param("absorb", Vector3(0.030, 0.012, 0.008))
	sim.set_param("scatter", 0.018)
	sim.set_param("foam_strength", 0.45)
	sim.set_param("caustic_strength", 0.18)
	sim.set_param("liquid_specular", 0.45)
	# Incandescence reads the authoritative thermal layer when the simulator
	# provides one; without it the shaders never sample the uniform.
	if "thermal_texture" in sim and sim.thermal_texture != null:
		sim.set_param("thermal", sim.thermal_texture)
		sim.set_param("thermal_glow", true)
	return sun
