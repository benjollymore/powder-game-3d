extends SceneTree
## Every example builds at the session grid with only table materials and a
## thermal layer of the right size. Headless; run once per grid:
##   godot --headless --path . -s res://tests/milestone/examples_cpu.gd -- grid=128
##   godot --headless --path . -s res://tests/milestone/examples_cpu.gd -- grid=256
var checks := 0
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])
## Scenarios.build returns voxels today; the pinned contract lets it grow into
## {voxels, thermal}. Accept both, and derive the default layer otherwise.
static func layers(name: String) -> Dictionary:
	var built = Scenarios.build(name)
	if built is Dictionary:
		var voxels: PackedByteArray = built.voxels.to_byte_array() if built.voxels is PackedInt32Array else built.voxels
		var thermal: PackedByteArray = built.thermal.to_byte_array() if built.thermal is PackedFloat32Array else built.thermal
		return {"voxels": voxels, "thermal": thermal, "explicit": true}
	return {"voxels": built, "thermal": WorldArchive.default_thermal(built), "explicit": false}
func run() -> void:
	var n := VoxelCodec.GRID
	var cells := n * n * n
	var names := Scenarios.names()
	check(names.size() >= 8 and "Empty" in names and names.size() == Array(names).reduce(func(acc, name): return acc + (1 if Array(names).count(name) == 1 else 0), 0),
		"scenario names are unique and include Empty (%d at %d³)" % [names.size(), n])
	for name in names:
		var built := layers(name)
		var voxels: PackedByteArray = built.voxels
		var thermal: PackedByteArray = built.thermal
		check(voxels.size() == cells * 4, "%s builds %d³ voxels" % [name, n])
		var bad_id := -1
		var count := Elements.count()
		var used := {}
		for i in cells:
			var id := voxels[i * 4]
			if id >= count:
				bad_id = id
				break
			used[id] = true
		check(bad_id < 0, "%s uses only table materials (offending id %d)" % [name, bad_id])
		check(thermal.size() == cells * 8, "%s has a thermal layer of %d bytes per cell (%s)" % [name, 8, "explicit" if built.explicit else "element defaults"])
		var finite := true
		var min_t := INF
		var max_t := -INF
		for i in cells:
			var t := thermal.decode_float(i * 8)
			if not is_finite(t):
				finite = false
				break
			min_t = minf(min_t, t)
			max_t = maxf(max_t, t)
		check(finite and min_t > 0.0, "%s temperatures are finite and above absolute zero (%.1f..%.1f K)" % [name, min_t, max_t])
		check(name == "Empty" or used.size() >= 2, "%s places at least one material besides air (%d kinds)" % [name, used.size() - int(used.has(0))])
		if name != "Empty":
			var second := layers(name)
			check(second.voxels == voxels and second.thermal == thermal, "%s builds deterministically" % name)
	print("Examples CPU (%d³): %d checks, %d failures" % [n, checks, failures])
	quit(1 if failures else 0)
