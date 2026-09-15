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
	# Grouping from a table without category keys uses the built-in fallback.
	var groups := PalettePanel.grouped()
	check(groups.get("common", []) == [Elements.Id.WALL, Elements.Id.SAND, Elements.Id.WATER] and groups.get("heat", []) == [Elements.Id.FIRE],
		"table without category keys groups the known ids by the fallback map")
	check(groups.get("gases", []) == [Elements.Id.STEAM, Elements.Id.SMOKE] and groups.get("solids", []) == [Elements.Id.PLANT, Elements.Id.WOOD] and groups.get("liquids", []) == [Elements.Id.OIL],
		"fallback map places oil, wood, plant, steam and smoke in their categories")
	# Grouping from a table with explicit keys follows those keys, including new ids.
	var table: Array = []
	for row in Elements.TABLE:
		table.append(row.duplicate())
	table[Elements.Id.OIL]["category"] = "special"
	table[Elements.Id.OIL]["tip"] = "Floats and burns"
	table.append({"name": "Lava", "color": Color.RED, "flags": 0, "category": "heat", "tip": "Hot rock"})
	table.append({"name": "Acid", "color": Color.GREEN, "flags": 0, "category": "liquids"})
	var keyed := PalettePanel.grouped_from(table)
	check(keyed.get("special", []) == [Elements.Id.OIL] and keyed.get("heat", []) == [Elements.Id.FIRE, table.size() - 2] and keyed.get("liquids", []) == [table.size() - 1],
		"explicit category keys override the fallback and admit new ids")
	check(PalettePanel.category_for(table[Elements.Id.OIL], Elements.Id.OIL) == "special" and PalettePanel.category_for({"name": "X"}, 99) == "special",
		"unknown ids without a category key land in Special")
	var lab = load("res://tests/milestone/heat_ui_lab.gd").new()
	root.add_child(lab)
	await process_frame
	var palette = lab.palette
	check(palette.first_row == [Elements.Id.SAND, Elements.Id.WATER, Elements.Id.WALL], "first row is Sand, Water, Wall")
	check(palette.heat_row_ids == [Elements.Id.FIRE] and not palette.heat_button.visible and not palette.cool_button.visible,
		"heat row shows Fire and hides thermal brushes while the simulator has no HEAT/COOL modes")
	check(palette.tab_buttons.keys() == ["liquids", "gases", "solids"] and lab.material_buttons.size() == 9,
		"one tab per remaining category, every non-air material has a button")
	check(lab.material_buttons[Elements.Id.OIL].tooltip_text == "Oil" and not palette.grids["liquids"].visible,
		"tooltips fall back to the material name and tab contents start hidden")
	palette.tab_buttons["gases"].button_pressed = true
	check(palette.grids["gases"].visible and not palette.grids["liquids"].visible and palette.active_tab == "gases", "a tab reveals only its own materials")
	palette.tab_buttons["solids"].button_pressed = true
	check(palette.grids["solids"].visible and not palette.grids["gases"].visible, "choosing another tab hides the previous one")
	lab._choose_material(Elements.Id.STEAM)
	check(lab.element == Elements.Id.STEAM and lab.material_buttons[Elements.Id.STEAM].button_pressed, "materials inside a tab select like the fixed rows")
	lab._choose_thermal("heat")
	check(lab.thermal_tool == "" and lab.element == Elements.Id.STEAM, "thermal brushes cannot be selected while the simulator lacks them")
	check(lab._brush_mode("heat", false) == lab.sim.BrushMode.ONLY_AIR and lab._brush_mode("", true) == lab.sim.BrushMode.ERASE,
		"brush mode ignores an unavailable thermal tool and keeps erase/add semantics")
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
	lab.queue_free()
	await process_frame
	print("Heat UI CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
