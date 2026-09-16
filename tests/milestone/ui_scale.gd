extends SceneTree
## The sidebar scales with the window. Builds the real editor UI over the
## paint-tools stub simulator and resizes the window under it, so this covers
## the live `size_changed` path a person exercises by dragging a window edge,
## not just the arithmetic.
const UiScale := preload("res://scripts/editor/ui_scale.gd")
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

func run() -> void:
	# --- the factor itself ---
	check(is_equal_approx(UiScale.factor(UiScale.BASE), 1.0),
		"the project's default viewport scales by exactly 1.0, so the authored layout is unchanged")
	check(is_equal_approx(UiScale.factor(Vector2(1280, 800)), 0.8),
		"a 1280x800 laptop takes the smaller of the two axis ratios (0.8)")
	check(UiScale.factor(Vector2(3200, 900)) < 1.01,
		"a wide but short window is limited by its height, so the pinned status keeps its room")
	check(is_equal_approx(UiScale.factor(Vector2(320, 200)), UiScale.MIN_FACTOR),
		"an absurdly small window clamps to the readable lower bound")
	check(is_equal_approx(UiScale.factor(Vector2(12000, 8000)), UiScale.MAX_FACTOR),
		"a very large display clamps, so the sidebar cannot eat the world view")
	check(is_equal_approx(UiScale.factor(Vector2(0, 0)), 1.0),
		"a degenerate viewport falls back to 1.0 rather than dividing by zero")
	check(UiScale.font_size(16, 0.8) == 13 and UiScale.font_size(16, 1.0) == 16,
		"font sizes round to whole pixels and never reach zero")

	# --- the real UI, resized under itself ---
	root.size = Vector2i(1600, 900)
	root.get_node("TimeController").set_process_unhandled_input(false)
	var editor = load("res://tests/milestone/heat_ui_lab.gd").new()
	root.add_child(editor)
	await process_frame
	await process_frame
	check(editor.tools_panel != null, "the editor built its sidebar over the stub simulator")

	var sizes := [Vector2i(1100, 700), Vector2i(1280, 800), Vector2i(1600, 900),
			Vector2i(2560, 1440), Vector2i(6016, 3384)]
	var widths: Array[float] = []
	var fonts: Array[int] = []
	for size in sizes:
		root.size = size
		await process_frame
		await process_frame
		var panel: Control = editor.tools_panel
		var rect := panel.get_global_rect()
		widths.append(panel.size.x)
		fonts.append(editor.ui_theme.default_font_size)
		check(rect.end.x <= float(size.x),
			"at %dx%d the sidebar stays inside the window (right edge %.0f of %d)" % [size.x, size.y, rect.end.x, size.x])
		check(rect.end.y <= float(size.y),
			"at %dx%d the sidebar stays inside the window vertically (bottom %.0f of %d)" % [size.x, size.y, rect.end.y, size.y])
		check(panel.size.x <= float(size.x) * 0.45,
			"at %dx%d the sidebar leaves most of the window to the world (%.0f wide)" % [size.x, size.y, panel.size.x])
		check(editor.status != null and editor.status.get_global_rect().end.y <= rect.end.y + 1.0,
			"at %dx%d the pinned status stays inside the sidebar" % [size.x, size.y])
		check(panel.size.x >= panel.get_combined_minimum_size().x,
			"at %dx%d the sidebar is never narrower than its own controls need (%.0f of %.0f)"
				% [size.x, size.y, panel.size.x, panel.get_combined_minimum_size().x])

	var growing := true
	for i in range(1, fonts.size()):
		growing = growing and fonts[i] >= fonts[i - 1]
	check(growing, "font size never shrinks as the window grows (%s)" % [fonts])
	var scaled := true
	for i in range(1, widths.size()):
		scaled = scaled and widths[i] >= widths[i - 1]
	check(scaled, "sidebar width grows with the window at every step (%s)" % [widths])
	check(widths[0] < widths[-1] and fonts[0] < fonts[-1],
		"a 6K display really does get a larger sidebar than a small laptop (%.0f to %.0f px wide, font %d to %d)"
			% [widths[0], widths[-1], fonts[0], fonts[-1]])

	# The default size must reproduce the authored geometry exactly.
	root.size = Vector2i(1600, 900)
	# Shrinking back from 6K, the controls relayout over several frames before
	# the panel can return to its authored width.
	for i in 8:
		await process_frame
	check(is_equal_approx(editor.tools_panel.size.x, UiScale.PANEL_WIDTH) and editor.ui_theme.default_font_size == UiScale.BASE_FONT,
		"back at the default viewport the sidebar returns to the authored layout (%.0f px wide, font %d)"
			% [editor.tools_panel.size.x, editor.ui_theme.default_font_size])

	# Scaling is a 2D concern only: the pointer stays in real pixels, which is
	# what the pick converts into a ray.
	check(is_equal_approx(root.get_visible_rect().size.x, 1600.0),
		"the viewport's visible rect still matches the window, so picks keep landing under the pointer")
	check(root.content_scale_factor == 1.0,
		"Godot's own content scaling is left alone, so the raymarched view is not resampled")

	editor.queue_free()
	await process_frame
	print("UI scale: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
