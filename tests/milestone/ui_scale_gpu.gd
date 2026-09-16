extends "res://tests/milestone/editor_workflow_gpu.gd"
## The sidebar scales with the window; the pointer must not. The same parsed
## drag over the same world cells has to paint the same cells whatever the
## window size, because the pick turns a mouse position into a ray and the
## scaling deliberately leaves the viewport in real pixels.
##
## Screen coordinates legitimately differ between sizes: `point()` unprojects
## through the camera, so the comparison is of changed CELLS, never of pixels.

const SIZES := [Vector2i(1600, 900), Vector2i(1280, 800), Vector2i(2240, 1260)]

func changed_cells(before: PackedByteArray, after: PackedByteArray) -> Dictionary:
	var out := {}
	for i in range(0, before.size(), 4):
		if before[i] != after[i]:
			out[i / 4] = after[i]
	return out


## Build the editor at `size`, run one fixed drag, and report what it painted
## plus the sidebar geometry that produced it.
func paint_at(size: Vector2i) -> Dictionary:
	root.size = size
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	clock = root.get_node("TimeController")
	await frames(12)
	var n := VoxelCodec.GRID
	var first := Vector3i(n * 3 / 8, n * 9 / 16, n / 2)
	var last := Vector3i(n * 5 / 8, n * 7 / 16, n / 2)
	await click(editor.material_buttons[Elements.Id.WALL])
	await frames(2)
	var before := await read()
	# The drag is authored in world cells, so the pointer path is whatever those
	# cells project to at this window size.
	move_to(point(first))
	await frames(1)
	mouse(true)
	for step in range(1, 9):
		move_to(point(first + (last - first) * step / 8))
		await frames(1)
	mouse(false)
	await frames(6)
	var after := await read()
	var result := {
		"cells": changed_cells(before, after),
		"panel": editor.tools_panel.size.x,
		"font": editor.ui_theme.default_font_size,
		"fits": editor.tools_panel.get_global_rect().end.x <= float(size.x)
			and editor.tools_panel.get_global_rect().end.y <= float(size.y),
		"content_fits": editor.tools_panel.size.x >= editor.tools_panel.get_combined_minimum_size().x,
		"visible": root.get_visible_rect().size,
	}
	editor.queue_free()
	await frames(4)
	return result


func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="):
			output_dir = arg.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(output_dir)
	original_cursor = DisplayServer.mouse_get_position()
	original_accumulation = Input.use_accumulated_input
	input_configured = true
	Input.use_accumulated_input = false

	var results: Array[Dictionary] = []
	for size in SIZES:
		results.append(await paint_at(size))

	var baseline: Dictionary = results[0]
	check(not baseline.cells.is_empty(), "the reference drag at 1600x900 painted something (%d cells)" % baseline.cells.size())
	for i in range(SIZES.size()):
		var size: Vector2i = SIZES[i]
		var r: Dictionary = results[i]
		check(r.fits, "at %dx%d the sidebar stays inside the window" % [size.x, size.y])
		check(r.content_fits, "at %dx%d the sidebar is at least as wide as its controls need (%.0f)" % [size.x, size.y, r.panel])
		check(is_equal_approx(r.visible.x, float(size.x)) and is_equal_approx(r.visible.y, float(size.y)),
			"at %dx%d the viewport's visible rect is the window itself, so the raymarch is not resampled" % [size.x, size.y])
		check(r.cells == baseline.cells,
			"at %dx%d the same drag paints exactly the same cells as at 1600x900 (%d vs %d)"
				% [size.x, size.y, r.cells.size(), baseline.cells.size()])

	check(results[1].panel < baseline.panel and results[2].panel > baseline.panel,
		"the sidebar really did resize with the window (%.0f, %.0f, %.0f px)"
			% [results[1].panel, baseline.panel, results[2].panel])
	check(results[1].font < baseline.font and results[2].font > baseline.font,
		"the font really did resize with the window (%d, %d, %d)"
			% [results[1].font, baseline.font, results[2].font])

	_restore_input()
	await frames(2)
	print("UI_SCALE_GPU_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
