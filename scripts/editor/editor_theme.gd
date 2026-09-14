extends RefCounted
## Shared visual hierarchy for the paint tools. No simulation or input policy.

static func panel_style(color: Color, border: Color, margin: int = 10) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(6)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = 7
	style.content_margin_bottom = 7
	return style

static func apply(panel: PanelContainer) -> void:
	var theme := Theme.new()
	theme.default_font_size = 15
	var normal := panel_style(Color("263747"), Color("3c5062"))
	var hover := panel_style(Color("344c60"), Color("7293ad"))
	var pressed := panel_style(Color("2c5c65"), Color("78c8c5"))
	var disabled := panel_style(Color("24313e"), Color("334452"))
	var focus := panel_style(Color(0, 0, 0, 0), Color("b2e6e0"))
	focus.set_border_width_all(2)
	for control in ["Button", "OptionButton"]:
		theme.set_stylebox("normal", control, normal)
		theme.set_stylebox("hover", control, hover)
		theme.set_stylebox("pressed", control, pressed)
		theme.set_stylebox("disabled", control, disabled)
		theme.set_stylebox("focus", control, focus)
		theme.set_color("font_color", control, Color("e8eff4"))
		theme.set_color("font_hover_color", control, Color.WHITE)
		theme.set_color("font_pressed_color", control, Color.WHITE)
		theme.set_color("font_disabled_color", control, Color("8798a8"))
	theme.set_color("font_color", "Label", Color("d0dce7"))
	theme.set_color("font_color", "CheckButton", Color("d0dce7"))
	theme.set_stylebox("normal", "LineEdit", panel_style(Color("16232e"), Color("405668"), 8))
	theme.set_stylebox("focus", "LineEdit", focus)
	theme.set_color("font_color", "LineEdit", Color("edf5fa"))
	theme.set_constant("separation", "VBoxContainer", 8)
	theme.set_constant("separation", "HBoxContainer", 6)
	panel.theme = theme
	panel.add_theme_stylebox_override("panel", panel_style(Color("182532f5"), Color("40586d"), 14))
