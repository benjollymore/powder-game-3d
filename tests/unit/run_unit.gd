extends SceneTree
## Headless unit tests: `godot --headless --path . -s res://tests/unit/run_unit.gd`
## Plain asserts, no plugin. Exit code 0 on success, 1 on failure.

const TimeControllerScript := preload("res://scripts/time_controller.gd")

var _failures := 0
var _checks := 0


func _initialize() -> void:
	_test_time_controller()
	_test_liquid_constants()
	_test_scenarios()
	_test_elements()
	_test_scenario_oracle()
	print("%d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("FAIL: " + msg)


func _test_time_controller() -> void:
	var f := TimeControllerScript.compute_ticks
	var tps := 180.0
	var frame := 1.0 / 60.0

	var r: Array = f.call(frame, true, 1.0, 0, 0.0)
	check(r[0] == 0, "paused runs no ticks")
	check(r[1] == 0.0, "paused does not accumulate")

	r = f.call(frame, true, 1.0, 1, 0.0)
	check(r[0] == 1, "step while paused runs exactly one tick")

	# Real time at 60 fps: TICKS_PER_SECOND ticks per second.
	var acc := 0.0
	var total := 0
	for i in 60:
		r = f.call(frame, false, 1.0, 0, acc)
		total += r[0]
		acc = r[1]
	check(absf(total - tps) <= 1.0, "scale 1.0 at 60 fps gives ~%d ticks/s, got %d" % [tps, total])

	# Half speed.
	acc = 0.0
	total = 0
	for i in 60:
		r = f.call(frame, false, 0.5, 0, acc)
		total += r[0]
		acc = r[1]
	check(absf(total - tps / 2.0) <= 1.0, "scale 0.5 gives ~%d ticks/s, got %d" % [tps / 2, total])

	# Frozen scale runs nothing.
	r = f.call(frame, false, 0.0, 0, 0.0)
	check(r[0] == 0, "scale 0 runs no ticks")

	# Huge frame is capped and the backlog is dropped.
	r = f.call(1.0, false, 4.0, 0, 0.0)
	check(r[0] == 8, "ticks per frame are capped")
	check(r[1] == 0.0, "backlog dropped after cap")
	check(VoxelCodec.GRID % 8 == 0, "resolved grid size %d is a multiple of 8" % VoxelCodec.GRID)


func _test_liquid_constants() -> void:
	var glsl := FileAccess.get_file_as_string("res://shaders/compute/sim.glsl")
	check(glsl.contains("const uint FULL = %du;" % Elements.LIQUID_FULL),
		"sim.glsl FULL matches Elements.LIQUID_FULL")
	check(VoxelCodec.amount_of(VoxelCodec.encode(3, 77, 200)) == 200, "amount round-trips through encode")
	check(VoxelCodec.element_id(VoxelCodec.encode(3, 77, 200)) == 3, "id survives amount packing")
	check(VoxelCodec.seed_of(VoxelCodec.encode(3, 77, 200)) == 77, "seed survives amount packing")


func _test_scenarios() -> void:
	var n := VoxelCodec.GRID
	for name in Scenarios.names():
		var t0 := Time.get_ticks_msec()
		var bytes := Scenarios.build(name)
		var ms := Time.get_ticks_msec() - t0
		check(bytes.size() == n * n * n * 4, "scenario '%s' has the right size" % name)
		var k := float(VoxelCodec.GRID) / 128.0
		check(ms < 1000 * k * k * k, "scenario '%s' CPU build is within budget (%d ms; the game builds scenarios on the GPU)" % [name, ms])
		var nonair := 0
		for i in range(0, bytes.size(), 4 * 64):
			if bytes[i] != 0:
				nonair += 1
		check(nonair > 0, "scenario '%s' is not empty" % name)


func _test_elements() -> void:
	var problems := Elements.validate()
	check(problems.is_empty(), "element table validates: " + ", ".join(problems))
	var include := FileAccess.get_file_as_string(Elements.ELEM_INCLUDE)
	var re := RegEx.create_from_string("ELEM_BYTES_SENTINEL\\s+(\\d+)u")
	var m := re.search(include)
	check(m != null and int(m.get_string(1)) == Elements.ELEM_BYTES, "shader Elem sentinel matches Elements.ELEM_BYTES (%d)" % Elements.ELEM_BYTES)
	check(Elements.ELEM_BYTES % 16 == 0, "Elem record is 16-byte aligned for std430")
	var bytes := Elements.property_bytes()
	check(bytes.size() == Elements.count() * Elements.ELEM_BYTES, "property buffer is count * ELEM_BYTES")
	# Original 32-byte prefix is unchanged for every element.
	var water := Elements.Id.WATER * Elements.ELEM_BYTES
	check(bytes.decode_u32(water) == Elements.FLAG_LIQUID and is_equal_approx(bytes.decode_float(water + 4), 100.0), "water prefix packs flags and density as before")
	check(is_equal_approx(bytes.decode_float(water + 32), 4.18) and is_equal_approx(bytes.decode_float(water + 52), 373.15), "water thermal fields pack capacity and hot_at")
	check(bytes.decode_u32(water + 64) & 0xFF == Elements.Id.STEAM, "water hot_to packs into ids.x")
	check(Elements.thermal(Elements.Id.WALL, "hot_to") == 0.0 and Elements.thermal(Elements.Id.SAND, "ignition_temp") == 0.0, "defaults apply where a row is silent")
	var reacts := Elements.reaction_bytes()
	check(reacts.size() == Elements.REACTIONS.size() * 16, "reaction buffer is 16 bytes per rule")
	check(reacts.decode_float(8) == 0.0 and reacts.decode_float(12) == 0.0, "rules without a thermal dictionary encode zero min_t and heat")
	check(Elements.PALETTE_SIZE >= Elements.count(), "palette holds every element")


## CPU-replay oracle for the heat milestone scenarios, pinned per grid size as
## the SHA-256 of the built world. A deliberate scenario edit re-pins it.
const SCENARIO_ORACLE := {
	128: {
		"Candle": "fbf188db49f6bc9bba9b252aa9e505509b38a1240d37127bc088fb37734fa124",
		"Powder keg": "c3de548bba4ae045e24005a10eac72f6ec499f8d13e020244f2133b526ed71d1",
		"Acid rain": "c3722de0e6b0b506bfcf107b801c1518d6935a1395aca263d79e308386636a3c",
		"Volcano": "1bcaf3c1194e68436ad6b576687f47ca0031a43d4a37ce4ba7c0008b6ee506b9",
		"Ice cave": "eee16a112e6c536490f561b32be033f57e23c0e320f2eb92f5e9985a4a00da72",
		"Boiler": "10223877c6f41bbc27a4862e141166000ed1089aa0d16b8ac177a50a625793f8",
		"Foundry": "ae1ff20525679ecdb3f235663b491f4eaaa54cbefb0996fccea049d2f7c9ecbc",
	},
	256: {
		"Candle": "c888f8470cc38e43dc5336ef52fa12d2d0931e0b6f2c1a59a0b94c76fb62528b",
		"Powder keg": "43e70f2930bc577ff97e23dc3c0b37cae58d5ab46b49bd745bdcef1b3dd2520a",
		"Acid rain": "a51a82f7b95ea106f20a6991cbac0948b5520a9f29a218ae6a6e9c2fb190be5e",
		"Volcano": "1f5e001bee07176f6dcc50433051135b7d141cc4892632c04dffa42eb9607b07",
		"Ice cave": "6d9f3172b5bd081076deed7b35768b15ebf5990d35c5906b0e048c974083640f",
		"Boiler": "9eedc81e4fda503d3b07e6d496d6b01a7e6da6124f0e2f74bf7d48eda0f7a4cd",
		"Foundry": "dd92769615a7fbfcc65d1550fd137a019f091041645ac4cb635b713f5b13291d",
	},
}


func _test_scenario_oracle() -> void:
	if not SCENARIO_ORACLE.has(VoxelCodec.GRID):
		return
	var pinned: Dictionary = SCENARIO_ORACLE[VoxelCodec.GRID]
	for name in pinned:
		var ctx := HashingContext.new()
		ctx.start(HashingContext.HASH_SHA256)
		ctx.update(Scenarios.build(name))
		var actual := ctx.finish().hex_encode()
		check(actual == pinned[name], "scenario '%s' CPU build matches its pinned oracle at %d (got %s)" % [name, VoxelCodec.GRID, actual])
