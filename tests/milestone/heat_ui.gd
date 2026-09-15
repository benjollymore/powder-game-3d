extends SceneTree
## Palette construction, number keys, speed binding and the Examples guard
## flow, headless, over the paint-tools stub simulator.
const PalettePanel := preload("res://scripts/editor/palette_panel.gd")
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
func key(code: int) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.pressed = down
		Input.parse_input_event(event)
func run() -> void:
	root.size = Vector2i(1280, 800)
	Input.use_accumulated_input = false
	root.get_node("TimeController").set_process_unhandled_input(false)
	# The real table carries category and tip keys; the panel follows them.
	var groups := PalettePanel.grouped()
	var expected := {}
	for id in range(1, Elements.count()):
		var category: String = Elements.TABLE[id].category
		if not expected.has(category):
			expected[category] = []
		expected[category].append(id)
	check(groups == expected, "grouping follows the table's own category keys")
	check(PalettePanel.tip_of(Elements.Id.OIL) == Elements.TABLE[Elements.Id.OIL].tip, "tooltips come from the table's tip key")
	# A table without those keys (older rows, external tables) uses the fallback map.
	var keyless: Array = []
	for row in Elements.TABLE:
		var copy: Dictionary = row.duplicate()
		copy.erase("category")
		copy.erase("tip")
		keyless.append(copy)
	var fallback := PalettePanel.grouped_from(keyless)
	check(fallback.get("common", []) == [Elements.Id.WALL, Elements.Id.SAND, Elements.Id.WATER] and fallback.get("heat", []) == [Elements.Id.FIRE],
		"keyless rows group the known ids by the fallback map")
	check(fallback.get("gases", []) == [Elements.Id.STEAM, Elements.Id.SMOKE] and fallback.get("solids", []) == [Elements.Id.PLANT, Elements.Id.WOOD] and fallback.get("liquids", []) == [Elements.Id.OIL],
		"fallback map places oil, wood, plant, steam and smoke in their categories")
	check(PalettePanel.tip_for(keyless[Elements.Id.OIL]) == "Oil", "a row without a tip falls back to its name")
	# Explicit keys override the fallback and admit new ids.
	var table: Array = keyless.duplicate(true)
	table[Elements.Id.OIL]["category"] = "special"
	table[Elements.Id.OIL]["tip"] = "Floats and burns"
	table.append({"name": "Lava", "color": Color.RED, "flags": 0, "category": "heat", "tip": "Hot rock"})
	table.append({"name": "Acid", "color": Color.GREEN, "flags": 0, "category": "liquids"})
	var keyed := PalettePanel.grouped_from(table)
	check(Elements.Id.OIL in keyed.get("special", []) and Elements.Id.OIL not in keyed.get("liquids", []) and Elements.Id.FIRE in keyed.get("heat", [])
		and table.size() - 2 in keyed.get("heat", []) and table.size() - 1 in keyed.get("liquids", []),
		"explicit category keys override the fallback and admit new ids")
	check(PalettePanel.category_for(table[Elements.Id.OIL], Elements.Id.OIL) == "special" and PalettePanel.category_for({"name": "X"}, 99) == "special",
		"unknown ids without a category key land in Special")
	var lab = load("res://tests/milestone/heat_ui_lab.gd").new()
	root.add_child(lab)
	await process_frame
	var palette = lab.palette
	check(palette.first_row == [Elements.Id.SAND, Elements.Id.WATER, Elements.Id.WALL], "first row is Sand, Water, Wall")
	var heat_names: Array = []
	for id in palette.heat_row_ids:
		heat_names.append(String(Elements.TABLE[id].name))
	var heat_expected: Array = ["Fire"]
	for name in ["Lava", "Ice"]:
		if PalettePanel.id_named(name) > 0:
			heat_expected.append(name)
	check(heat_names.slice(0, heat_expected.size()) == heat_expected and heat_names.all(func(name): return PalettePanel.category_of(PalettePanel.id_named(name)) == "heat" or name == "Fire")
		and not palette.heat_button.visible and not palette.cool_button.visible,
		"heat row leads with Fire, Lava and Ice when the table has them, only heat-category materials follow, and thermal brushes hide while the simulator has no HEAT/COOL modes (row: %s)" % str(heat_names))
	var tabs_expected: Array = []
	for category in PalettePanel.TAB_ORDER:
		if expected.has(category) and expected[category].any(func(id): return id not in palette.first_row and id not in palette.heat_row_ids):
			tabs_expected.append(category)
	check(palette.tab_buttons.keys() == tabs_expected and lab.material_buttons.size() == Elements.count() - 1,
		"one tab per remaining category, every non-air material has a button")
	check(lab.material_buttons[Elements.Id.OIL].tooltip_text == Elements.TABLE[Elements.Id.OIL].tip and not palette.grids["liquids"].visible,
		"buttons show the table tip and tab contents start hidden")
	palette.tab_buttons["gases"].button_pressed = true
	check(palette.grids["gases"].visible and not palette.grids["liquids"].visible and palette.active_tab == "gases", "a tab reveals only its own materials")
	palette.tab_buttons["solids"].button_pressed = true
	check(palette.grids["solids"].visible and not palette.grids["gases"].visible, "choosing another tab hides the previous one")
	lab._choose_material(Elements.Id.STEAM)
	check(lab.element == Elements.Id.STEAM and lab.material_buttons[Elements.Id.STEAM].button_pressed, "materials inside a tab select like the fixed rows")
	lab._choose_thermal("heat")
	check(lab.thermal_tool == "" and lab.element == Elements.Id.STEAM, "thermal brushes cannot be selected while the simulator lacks them")
	check(lab._brush_mode(false) == lab.sim.BrushMode.ONLY_AIR and lab._brush_mode(true) == lab.sim.BrushMode.ERASE,
		"material brush mode keeps erase/add semantics")
	for pair in [[KEY_1, Elements.Id.SAND], [KEY_2, Elements.Id.WATER], [KEY_3, Elements.Id.WALL]]:
		key(pair[0])
	check(lab.element == Elements.Id.WALL, "number keys follow the first row order")
	key(KEY_1)
	key(KEY_9)
	check(lab.element == Elements.Id.SAND, "an unassigned number key leaves the selection alone")
	check(palette.key_material(4) == -1 and palette.key_material(0) == -1, "key lookup rejects numbers beyond the row")
	# Speed slider: Build never drives the clock; Test does; external changes sync back.
	var clock = root.get_node("TimeController")
	clock.time_scale = 1.0
	lab.speed_slider.value = -3
	check(is_equal_approx(lab.speed_scale, 0.125) and lab.speed_label.text.begins_with("Speed 1/8") and clock.time_scale == 1.0,
		"speed slider stores 1/8x in Build without touching the clock")
	lab.testing = true
	lab.speed_slider.value = 2
	check(is_equal_approx(clock.time_scale, 4.0) and lab.speed_label.text.begins_with("Speed 4"), "in Test the slider drives the clock to 4x")
	clock.time_scale = 0.5
	check(lab.speed_slider.value == -1 and is_equal_approx(lab.speed_scale, 0.5), "keyboard time changes sync back to the slider")
	clock.time_scale = 1.0
	lab.testing = false
	# Examples: an entry routes through the guard as its own action kind.
	var names := Scenarios.names()
	check(lab.examples_choice.item_count == names.size() and lab.examples_choice.get_item_text(0) == "Examples…" and lab.examples_choice.is_item_disabled(0),
		"Examples lists every scenario except Empty behind a disabled placeholder")
	lab.examples_choice.select(2)
	lab.examples_choice.item_selected.emit(2)
	check(lab.document_guard.kinds == ["example"] and lab.examples_choice.selected == 0, "choosing an example asks the guard and resets the picker")
	lab.document_guard.callbacks[0].call()
	check(lab.sim.uploads.size() == 1 and lab.sim.uploads[0] == Scenarios.build(lab.examples_choice.get_item_text(2)) and not lab.document.is_dirty(),
		"the guard continuation replaces the build with the example's exact bytes as a clean untitled world")
	lab.capturing = true
	lab.load_example("Demo")
	check(lab._queued_editor_action == "example" and lab.document_guard.kinds.size() == 1, "an example chosen mid-capture waits like other editor actions")
	lab.capturing = false
	await process_frame
	await process_frame
	check(lab.document_guard.kinds == ["example", "example"], "the waiting example request resumes after the capture")
	lab.load_example("No such scenario")
	check(lab.document_guard.kinds.size() == 2, "unknown example names are ignored")
	# Ambient temperature lives in the advanced tools and drives the simulator's default.
	check(lab.ambient_input.value == 20 and lab.ambient_input.get_parent().get_parent() == lab.advanced_tools, "ambient control starts at 20 °C inside Tools & view options")
	lab.ambient_input.value = -5
	check(is_equal_approx(lab.sim.ambient_temp, 268.15), "ambient control sets the simulator's ambient kelvin")
	# The inspector never probes a simulator without the probe API and hides while painting.
	lab.painting = true
	lab._update_probe(true)
	check(lab.probe_text.is_empty() and not lab.probe_pending, "no probe is requested from a simulator without cell probes")
	# Reading the world without a thermal layer yields empty thermal bytes.
	var got: Array = [] # lambdas capture by value; an array is shared by reference
	lab.read_world(func(bytes, thermal): got.append({"bytes": bytes, "thermal": thermal}))
	check(got.size() == 1 and got[0].bytes == PackedByteArray([1, 2, 3, 4]) and got[0].thermal.is_empty(), "read_world returns voxels with an empty thermal layer when unsupported")
	lab.queue_free()
	await process_frame
	print("Heat UI CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
