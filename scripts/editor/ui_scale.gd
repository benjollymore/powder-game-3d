extends RefCounted
## The sidebar scales with the window: legible on a large display, inside the
## frame on a small one.
##
## Only the 2D theme is scaled. Godot's own content scaling
## (`Window.content_scale_factor` / `content_scale_mode`) is deliberately NOT
## used: setting a factor of 2 on a 1600x900 window leaves `size` at 1600x900
## but shrinks `get_visible_rect()` to 800x450, so the raymarched view would
## render at a fraction of the window and fight the Sharper/Faster picture
## preference, which owns `scaling_3d_scale`. It also moves canvas coordinates
## out of step with real pixels, and the editor feeds
## `get_viewport().get_mouse_position()` straight into `Camera3D.project_ray_*`:
## with a factor of 2 the screen centre projected as the bottom-right corner,
## so every pick and stroke would land away from the pointer.
##
## Scaling the theme instead leaves the viewport pixel-exact, leaves 3D
## resolution entirely to `DisplayPreferences`, and leaves the input path in
## real pixels.

## The project's default viewport, and the size at which the factor is exactly
## 1.0 so the layout is unchanged from before this existed.
const BASE := Vector2(1600.0, 900.0)
## Below the lower bound the text stops being readable; above the upper bound a
## 6K display would give a comically large sidebar rather than a bigger world.
const MIN_FACTOR := 0.7
const MAX_FACTOR := 3.0
## Unscaled sidebar geometry, in the units the layout was authored in.
const PANEL_WIDTH := 390.0
const PANEL_MARGIN := 16.0
const BASE_FONT := 16
const SMALL_FONT := 14
const SPEED_LABEL_WIDTH := 90.0
const STATUS_WIDTH := 300.0

## Both axes matter: a short window must shrink the sidebar even when it is
## wide, or the pinned status falls off the bottom.
static func factor(viewport: Vector2) -> float:
	if viewport.x <= 0.0 or viewport.y <= 0.0:
		return 1.0
	return clampf(minf(viewport.x / BASE.x, viewport.y / BASE.y), MIN_FACTOR, MAX_FACTOR)


static func target_width(f: float) -> float:
	return PANEL_WIDTH * f


## The width to actually use: the scaled target, or the controls' own minimum
## when that is wider.
static func width_for(panel: Control, f: float) -> float:
	return maxf(target_width(f), panel.get_combined_minimum_size().x)


static func font_size(base: int, f: float) -> int:
	return maxi(1, int(round(float(base) * f)))


## Rebuild the theme and the sidebar's own geometry for the current window.
## Safe to call before every control exists, so the editor can call it from
## `size_changed` as well as once the UI is built.
static func apply(editor: Node, viewport: Vector2) -> float:
	var f := factor(viewport)
	var theme: Theme = editor.get("ui_theme")
	if theme != null:
		theme.default_font_size = font_size(BASE_FONT, f)
	var panel: Control = editor.get("tools_panel")
	if panel != null:
		var margin := PANEL_MARGIN * f
		panel.position = Vector2(margin, margin)
		# Never narrower than the controls themselves need: on a small window
		# the content's own minimum is the binding constraint, and forcing the
		# panel under it would clip the rows. On a shrink those minimums still
		# hold the previous, larger font's values for a frame or more, so the
		# editor re-asserts this target as they re-measure; see
		# `_settle_ui_scale`.
		panel.size = Vector2(width_for(panel, f), maxf(100.0, viewport.y - margin * 2.0))
	for name in ["controls_label", "secondary_controls_label"]:
		var label: Control = editor.get(name)
		if label != null:
			label.add_theme_font_size_override("font_size", font_size(SMALL_FONT, f))
	var speed: Control = editor.get("speed_label")
	if speed != null:
		speed.custom_minimum_size.x = SPEED_LABEL_WIDTH * f
	var status: Control = editor.get("status")
	if status != null:
		status.custom_minimum_size.x = minf(STATUS_WIDTH * f, PANEL_WIDTH * f - 16.0 * f)
	return f
