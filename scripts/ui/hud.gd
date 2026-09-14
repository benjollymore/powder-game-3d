extends CanvasLayer
## Top toolbar (time control, scenarios), bottom bar (element palette, brush),
## and a stats overlay (F3). Mirrors the keyboard shortcuts in TimeController,
## Brush and Atmosphere so both stay in sync.

@onready var play_button: Button = $Root/TopBar/H/PlayButton
@onready var step_button: Button = $Root/TopBar/H/StepButton
@onready var scale_slider: HSlider = $Root/TopBar/H/ScaleSlider
@onready var scale_label: Label = $Root/TopBar/H/ScaleLabel
@onready var scenario_option: OptionButton = $Root/TopBar/H/ScenarioOption
@onready var reload_button: Button = $Root/TopBar/H/ReloadButton
@onready var clear_button: Button = $Root/TopBar/H/ClearButton
@onready var frozen_label: Label = $Root/TopBar/H/FrozenLabel
@onready var dof_button: Button = $Root/TopBar/H/DofButton
@onready var stats: Label = $Root/Stats
@onready var palette: HBoxContainer = $Root/BottomBar/H/Palette
@onready var element_label: Label = $Root/BottomBar/H/V/ElementLabel
@onready var radius_slider: HSlider = $Root/BottomBar/H/V/RadiusRow/RadiusSlider
@onready var radius_label: Label = $Root/BottomBar/H/V/RadiusRow/RadiusLabel

var _brush: Node3D
var _sim: Node3D
var _atmosphere: Node3D
var _palette_buttons: Array[Button] = []
var _erase_button: Button
var _updating := false


func _ready() -> void:
	play_button.pressed.connect(TimeController.toggle_pause)
	step_button.pressed.connect(TimeController.step)
	scale_slider.value_changed.connect(_on_scale_slider)
	TimeController.paused_changed.connect(func(_p): _refresh_time())
	TimeController.time_scale_changed.connect(func(_s): _refresh_time())
	_refresh_time()

	_sim = get_tree().get_first_node_in_group("sim")
	if _sim:
		for name in Scenarios.names():
			scenario_option.add_item(name)
		scenario_option.item_selected.connect(func(i): _sim.load_scenario(scenario_option.get_item_text(i)))
		reload_button.pressed.connect(func(): _sim.load_scenario(_sim.current_scenario))
		clear_button.pressed.connect(_sim.clear)
		_sim.scenario_changed.connect(_refresh_scenario)
		_refresh_scenario(_sim.current_scenario)

	_atmosphere = get_tree().get_first_node_in_group("atmosphere")
	if _atmosphere:
		dof_button.button_pressed = _atmosphere.dof_enabled
		dof_button.toggled.connect(func(on): _atmosphere.dof_enabled = on)
	else:
		dof_button.visible = false

	_brush = get_tree().get_first_node_in_group("brush")
	if _brush:
		_build_palette()
		radius_slider.value_changed.connect(func(v): _brush.radius = int(v))
		_brush.changed.connect(_refresh_brush)
		_refresh_brush()
	else:
		$Root/BottomBar.visible = false


func _process(_delta: float) -> void:
	var tc := TimeController
	if stats.visible:
		stats.text = "FPS %d   process %.1f ms\nticks/s %.0f   tick %d\ntime x%.3f" % [
			Engine.get_frames_per_second(),
			Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
			tc.ticks_per_second,
			tc.tick,
			tc.effective_scale,
		]
		if _brush and _brush.cursor_valid:
			stats.text += "\ncursor %s" % [_brush.cursor_voxel]
	frozen_label.visible = tc.is_frozen()
	if _atmosphere and dof_button.button_pressed != _atmosphere.dof_enabled:
		dof_button.set_pressed_no_signal(_atmosphere.dof_enabled)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		stats.visible = not stats.visible
		get_viewport().set_input_as_handled()


# --- time ---------------------------------------------------------------------

func _on_scale_slider(value: float) -> void:
	if _updating:
		return
	# Slider is in log2 space: -5 .. 2  ->  1/32 .. 4
	TimeController.time_scale = pow(2.0, value)


func _refresh_time() -> void:
	var tc := TimeController
	play_button.text = "Play" if tc.paused else "Pause"
	scale_label.text = "%d%%" % int(round(tc.time_scale * 100.0))
	_updating = true
	scale_slider.value = log(maxf(tc.time_scale, tc.MIN_SCALE)) / log(2.0)
	_updating = false


func _refresh_scenario(name: String) -> void:
	for i in scenario_option.item_count:
		if scenario_option.get_item_text(i) == name:
			scenario_option.select(i)
			return


# --- brush --------------------------------------------------------------------

func _swatch_style(color: Color, pressed: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color.lightened(0.15) if pressed else color.darkened(0.15)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(4)
	if pressed:
		sb.set_border_width_all(2)
		sb.border_color = Color(1, 1, 1, 0.95)
	return sb


func _build_palette() -> void:
	for id in range(1, Elements.count()):
		var e: Dictionary = Elements.TABLE[id]
		var b := Button.new()
		b.text = str(id)
		b.tooltip_text = e["name"]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(44, 44)
		var col: Color = e["color"]
		b.add_theme_stylebox_override("normal", _swatch_style(col, false))
		b.add_theme_stylebox_override("hover", _swatch_style(col.lightened(0.1), false))
		b.add_theme_stylebox_override("pressed", _swatch_style(col, true))
		b.add_theme_stylebox_override("hover_pressed", _swatch_style(col, true))
		var text_col := Color.WHITE if col.get_luminance() < 0.55 else Color(0.1, 0.1, 0.12)
		b.add_theme_color_override("font_color", text_col)
		b.add_theme_color_override("font_pressed_color", text_col)
		b.add_theme_color_override("font_hover_color", text_col)
		b.pressed.connect(func():
			_brush.element = id
			_brush.erase = false)
		palette.add_child(b)
		_palette_buttons.append(b)
	_erase_button = Button.new()
	_erase_button.text = "X"
	_erase_button.tooltip_text = "Erase"
	_erase_button.toggle_mode = true
	_erase_button.custom_minimum_size = Vector2(44, 44)
	_erase_button.pressed.connect(func(): _brush.erase = not _brush.erase)
	palette.add_child(_erase_button)


func _refresh_brush() -> void:
	for i in _palette_buttons.size():
		_palette_buttons[i].set_pressed_no_signal((not _brush.erase) and (_brush.element == i + 1))
	_erase_button.set_pressed_no_signal(_brush.erase)
	element_label.text = "Erase" if _brush.erase else str(Elements.TABLE[_brush.element]["name"])
	_updating = true
	radius_slider.value = _brush.radius
	_updating = false
	radius_label.text = str(_brush.radius)
