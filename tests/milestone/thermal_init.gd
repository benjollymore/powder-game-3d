extends SceneTree
## CPU checks for the thermal layer's table plumbing: initial temperatures and
## capacities must come from Elements.thermal(), not from TABLE keys that the
## schema keeps elsewhere (review finding on the first thermal unit), the
## energy model must match the kernels' capacity floor, and brush modes must
## agree between the simulator and the editor brush.
##   godot --headless --path . -s res://tests/milestone/thermal_init.gd
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func run() -> void:
	var Sim := load("res://scripts/sim/voxel_sim.gd")
	var ambient := 293.15
	var temps: PackedFloat32Array = Sim.initial_temperatures(ambient)
	check(temps.size() == Elements.PALETTE_SIZE, "initial temperature table has one slot per palette entry")
	check(is_equal_approx(temps[Elements.Id.FIRE], 1200.0) and is_equal_approx(temps[Elements.Id.STEAM], 380.0)
		and is_equal_approx(temps[Elements.Id.LAVA], 1500.0), "fire, steam and lava start at their THERMAL initial temperatures (%.1f, %.1f, %.1f)" % [temps[Elements.Id.FIRE], temps[Elements.Id.STEAM], temps[Elements.Id.LAVA]])
	check(is_equal_approx(temps[Elements.Id.AIR], ambient) and is_equal_approx(temps[Elements.PALETTE_SIZE - 1], ambient), "air and unused ids start at ambient")
	var hot: PackedFloat32Array = Sim.initial_temperatures(350.0)
	check(is_equal_approx(hot[Elements.Id.AIR], 350.0) and is_equal_approx(hot[Elements.Id.WATER], Elements.thermal(Elements.Id.WATER, "initial_temp")), "a changed ambient moves air only")
	check(is_equal_approx(Sim.cell_capacity(Elements.Id.WATER, 200), 4.18) and is_equal_approx(Sim.cell_capacity(Elements.Id.WATER, 100), 2.09)
		and is_equal_approx(Sim.cell_capacity(Elements.Id.WATER, 1), 4.18 * 4.0 / 200.0), "liquid capacity scales with amount and floors at four units")
	check(is_equal_approx(Sim.cell_capacity(Elements.Id.WATER, 250), 4.18 * 1.25), "compressed liquid holds more heat")
	check(is_equal_approx(Sim.cell_capacity(Elements.Id.METAL, 0), 3.5) and is_equal_approx(Sim.cell_capacity(Elements.Id.AIR, 0), 0.05), "solids and air use their table capacity")

	# Energy of a tiny world: all air except one full water cell at 300 K and
	# one steam cell at 380 K carrying 10 J of latent progress.
	var n: int = VoxelCodec.GRID
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(5, 5, 5), Vector3i(6, 6, 6), Elements.Id.WATER, 200)
	WorldBuilder.fill_box(data, Vector3i(7, 5, 5), Vector3i(8, 6, 6), Elements.Id.STEAM)
	var voxels := data.to_byte_array()
	var thermal := PackedFloat32Array()
	thermal.resize(n * n * n * 2)
	for i in n * n * n:
		thermal[i * 2] = ambient
	thermal[VoxelCodec.index(5, 5, 5) * 2] = 300.0
	thermal[VoxelCodec.index(7, 5, 5) * 2] = 380.0
	thermal[VoxelCodec.index(7, 5, 5) * 2 + 1] = 10.0
	var expected := float(n * n * n - 2) * 0.05 * ambient + 4.18 * 300.0 + 0.05 * 380.0 + 10.0
	var total: float = Sim.energy_total(voxels, thermal.to_byte_array())
	check(absf(total - expected) <= 1e-6 * expected, "energy total sums capacity x temperature plus latent (%.3f vs %.3f)" % [total, expected])
	var region: float = Sim.energy_total(voxels, thermal.to_byte_array(), Vector3i(5, 5, 5), Vector3i(8, 6, 6))
	check(absf(region - (4.18 * 300.0 + 0.05 * ambient + 0.05 * 380.0 + 10.0)) < 1e-6, "energy total over a region counts only that region")

	var Brush := load("res://scripts/sim/brush.gd")
	check(Brush.Mode.HEAT == Sim.BrushMode.HEAT and Brush.Mode.COOL == Sim.BrushMode.COOL and Brush.Mode.ERASE == Sim.BrushMode.ERASE, "brush Mode mirrors VoxelSim.BrushMode")

	# Transition energies are symmetric: the lower phase's latent x capacity.
	var boil := Elements.thermal(Elements.Id.WATER, "latent") * Elements.thermal(Elements.Id.WATER, "heat_capacity")
	check(boil > 2000.0 and int(Elements.thermal(Elements.Id.STEAM, "cold_to")) == Elements.Id.WATER, "boiling and condensing share water's latent energy (%.0f J per cell)" % boil)
	check(int(Elements.thermal(Elements.Id.WATER, "cold_to")) == Elements.Id.ICE and int(Elements.thermal(Elements.Id.ICE, "hot_to")) == Elements.Id.WATER, "water freezes to ice and ice melts to water")
	check(int(Elements.thermal(Elements.Id.LAVA, "cold_to")) == Elements.Id.STONE and int(Elements.thermal(Elements.Id.STONE, "hot_to")) == Elements.Id.LAVA, "lava and stone are a phase pair")
	check(Elements.thermal(Elements.Id.WALL, "conductivity") == 0.0, "wall insulates")
	var interim := false
	for r in Elements.REACTIONS:
		if int(r[0]) == Elements.Id.FIRE and int(r[1]) == Elements.Id.WAX:
			interim = true
	check(not interim, "the interim contact-melt rule for wax is gone; melting is thermal")
	check(Elements.validate().is_empty(), "element table validates")
	print("Thermal init CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
