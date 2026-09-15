extends RefCounted
## Material palette built from `Elements.TABLE`. Rows: Common (always), Heat
## (fire, hot/cold materials and the thermal brushes when the simulator offers
## them), then one tab per remaining category. Works before the table carries
## `category`/`tip` keys: known ids fall back to the categories below.

const DEFAULT_CATEGORIES := {
	Elements.Id.SAND: "common", Elements.Id.WATER: "common", Elements.Id.WALL: "common",
	Elements.Id.FIRE: "heat", Elements.Id.OIL: "liquids", Elements.Id.WOOD: "solids",
	Elements.Id.PLANT: "solids", Elements.Id.STEAM: "gases", Elements.Id.SMOKE: "gases",
}
const COMMON_ORDER := ["Sand", "Water", "Wall"]
const HEAT_ORDER := ["Fire", "Lava", "Ice"]
const TAB_ORDER := ["powders", "liquids", "gases", "solids", "special"]
const TAB_LABELS := {"powders": "Powders", "liquids": "Liquids", "gases": "Gases", "solids": "Solids", "special": "Special"}

var first_row: Array[int] = []
var heat_row_ids: Array[int] = []
var tab_buttons := {}
var grids := {}
var heat_button: Button
var cool_button: Button
var active_tab := ""


static func category_of(id: int) -> String:
	return category_for(Elements.TABLE[id], id)


static func category_for(row: Dictionary, id: int) -> String:
	return String(row.get("category", DEFAULT_CATEGORIES.get(id, "special")))


static func tip_of(id: int) -> String:
	var row: Dictionary = Elements.TABLE[id]
	var tip := String(row.get("tip", ""))
	return tip if not tip.is_empty() else String(row.name)


static func id_named(name: String) -> int:
	for id in Elements.count():
		if String(Elements.TABLE[id].name) == name:
			return id
	return -1


## Category -> ordered ids, excluding Air and the ids shown in the fixed rows.
static func grouped() -> Dictionary:
	return grouped_from(Elements.TABLE)


static func grouped_from(table: Array) -> Dictionary:
	var groups := {}
	for id in range(1, table.size()):
		var category := category_for(table[id], id)
		if not groups.has(category):
			groups[category] = []
		groups[category].append(id)
	return groups


static func thermal_brushes_available(sim: Node) -> bool:
	if sim == null:
		return false
	var modes = sim.get("BrushMode")
	return modes is Dictionary and modes.has("HEAT") and modes.has("COOL")


func build(editor: Node3D, column: VBoxContainer) -> void:
	var groups := grouped()
	var placed := {}
	var common := HBoxContainer.new()
	column.add_child(common)
	for name in COMMON_ORDER:
		var id := id_named(name)
		if id > 0:
			first_row.append(id)
	for id in groups.get("common", []):
		if id not in first_row:
			first_row.append(id)
	for id in first_row:
		editor._add_material_button(common, id)
		editor.material_buttons[id].tooltip_text = tip_of(id)
		placed[id] = true
	var heat := HBoxContainer.new()
	column.add_child(heat)
	for name in HEAT_ORDER:
		var id := id_named(name)
		if id > 0 and not placed.has(id):
			heat_row_ids.append(id)
	for id in groups.get("heat", []):
		if not placed.has(id) and id not in heat_row_ids:
			heat_row_ids.append(id)
	for id in heat_row_ids:
		editor._add_material_button(heat, id)
		editor.material_buttons[id].tooltip_text = tip_of(id)
		placed[id] = true
	heat_button = _tool_button("Heat", "Warm what you paint over; nothing is added or removed", editor, "heat")
	cool_button = _tool_button("Cool", "Chill what you paint over; nothing is added or removed", editor, "cool")
	heat.add_child(heat_button)
	heat.add_child(cool_button)
	var available := thermal_brushes_available(editor.sim)
	heat_button.visible = available
	cool_button.visible = available
	var tabs := HBoxContainer.new()
	column.add_child(tabs)
	var categories: Array = []
	for category in TAB_ORDER:
		if groups.has(category):
			categories.append(category)
	for category in groups:
		if category not in categories and category not in ["common", "heat"]:
			categories.append(category)
	for category in categories:
		var ids: Array = []
		for id in groups[category]:
			if not placed.has(id):
				ids.append(id)
		if ids.is_empty():
			continue
		var tab := Button.new()
		tab.text = TAB_LABELS.get(category, String(category).capitalize())
		tab.toggle_mode = true
		tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab.tooltip_text = "Show %s" % tab.text.to_lower()
		tabs.add_child(tab)
		tab_buttons[category] = tab
		var grid := GridContainer.new()
		grid.columns = 3
		grid.visible = false
		column.add_child(grid)
		grids[category] = grid
		for id in ids:
			editor._add_material_button(grid, id)
			editor.material_buttons[id].tooltip_text = tip_of(id)
			placed[id] = true
		tab.toggled.connect(func(enabled): _show_tab(category if enabled else ""))


func _tool_button(text: String, tip: String, editor: Node3D, tool: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.toggle_mode = true
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(func(): editor._choose_thermal(tool))
	return button


func _show_tab(category: String) -> void:
	active_tab = category
	for name in tab_buttons:
		tab_buttons[name].set_pressed_no_signal(name == category)
		grids[name].visible = name == category


func refresh(editor: Node3D) -> void:
	if heat_button:
		heat_button.set_pressed_no_signal(editor.thermal_tool == "heat")
		cool_button.set_pressed_no_signal(editor.thermal_tool == "cool")


## Key 1..9 selects the n-th material of the first row; -1 when unassigned.
func key_material(number: int) -> int:
	if number < 1 or number > first_row.size():
		return -1
	return first_row[number - 1]
