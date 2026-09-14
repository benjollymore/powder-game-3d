extends CanvasLayer
## Stats readout, time-control bar, and brush palette. Mirrors the keyboard
## shortcuts in TimeController and Brush so both stay in sync.

@onready var stats: Label = $Stats
@onready var frozen_badge: Label = $FrozenBadge
@onready var pause_button: Button = $TimeBar/H/PauseButton
@onready var step_button: Button = $TimeBar/H/StepButton
@onready var scale_slider: HSlider = $TimeBar/H/ScaleSlider
@onready var scale_label: Label = $TimeBar/H/ScaleLabel
@onready var palette: HBoxContainer = $Tools/V/Palette
@onready var radius_slider: HSlider = $Tools/V/RadiusRow/RadiusSlider
@onready var radius_label: Label = $Tools/V/RadiusRow/RadiusLabel

var _brush: Node3D
var _palette_buttons: Array[Button] = []
var _erase_button: Button
var _updating := false


func _ready() -> void:
	pause_button.pressed.connect(TimeController.toggle_pause)
	step_button.pressed.connect(TimeController.step)
	scale_slider.value_changed.connect(_on_scale_slider)
	TimeController.paused_changed.connect(func(_p): _refresh_time())
	TimeController.time_scale_changed.connect(func(_s): _refresh_time())
	_refresh_time()

	_brush = get_tree().get_first_node_in_group("brush")
	if _brush:
		_build_palette()
		radius_slider.value_changed.connect(func(v): _brush.radius = int(v))
		_brush.changed.connect(_refresh_brush)
		_refresh_brush()
	else:
		$Tools.visible = false


func _process(_delta: float) -> void:
	var tc := TimeController
	stats.text = "FPS %d   process %.1f ms\nticks/s %.0f   tick %d\ntime x%.3f" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		tc.ticks_per_second,
		tc.tick,
		tc.effective_scale,
	]
	if _brush and _brush.cursor_valid:
		stats.text += "\ncursor %s" % [_brush.cursor_voxel]
	frozen_badge.visible = tc.is_frozen()


# --- time ---------------------------------------------------------------------

func _on_scale_slider(value: float) -> void:
	if _updating:
		return
	# Slider is in log2 space: -5 .. 2  ->  1/32 .. 4
	TimeController.time_scale = pow(2.0, value)


func _refresh_time() -> void:
	var tc := TimeController
	pause_button.text = "Resume" if tc.paused else "Pause"
	scale_label.text = "x" + String.num(tc.time_scale, 3)
	_updating = true
	scale_slider.value = log(maxf(tc.time_scale, tc.MIN_SCALE)) / log(2.0)
	_updating = false


# --- brush --------------------------------------------------------------------

func _build_palette() -> void:
	for id in range(1, Elements.count()):
		var e: Dictionary = Elements.TABLE[id]
		var b := Button.new()
		b.text = "%d %s" % [id, e["name"]]
		b.toggle_mode = true
		b.add_theme_color_override("font_color", e["color"].lightened(0.35))
		b.pressed.connect(func():
			_brush.element = id
			_brush.erase = false)
		palette.add_child(b)
		_palette_buttons.append(b)
	_erase_button = Button.new()
	_erase_button.text = "X Erase"
	_erase_button.toggle_mode = true
	_erase_button.pressed.connect(func(): _brush.erase = not _brush.erase)
	palette.add_child(_erase_button)


func _refresh_brush() -> void:
	for i in _palette_buttons.size():
		_palette_buttons[i].button_pressed = (not _brush.erase) and (_brush.element == i + 1)
	_erase_button.button_pressed = _brush.erase
	_updating = true
	radius_slider.value = _brush.radius
	_updating = false
	radius_label.text = str(_brush.radius)
