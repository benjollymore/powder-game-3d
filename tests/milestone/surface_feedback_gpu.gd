extends "res://tests/milestone/editor_workflow_gpu.gd"
## Reuses parsed input/cursor restoration helpers; both production frame loops
## stay enabled. This is injected input, not a physical trackpad test.
func preview() -> void:
	for i in 120:
		await process_frame
		if not editor.pick_pending and not editor.pick_cache.is_empty():
			await frames(2)
			return
	check(false, "surface preview completed within 120 frames")
func capture_pointer(name: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(output_dir.path_join(name + ".png"))
func run() -> void:
	output_dir = "/tmp/editor-surface-feedback/grid%d" % VoxelCodec.GRID
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			output_dir = argument.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(output_dir)
	original_cursor = DisplayServer.mouse_get_position()
	original_accumulation = Input.use_accumulated_input
	input_configured = true
	Input.use_accumulated_input = false
	root.size = Vector2i(1280, 800)
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	clock = root.get_node("TimeController")
	await frames(12)
	var original := await read()
	check(editor.is_processing() and clock.is_processing() and editor.section and not editor.advanced_tools.visible,
		"actual default editor keeps both frame loops active with a visible cutaway and closed construction tools")
	# Parsed mouse input opens the actual dropdown. In this macOS harness,
	# parsed root keys and explicit popup.push_input keys both failed to select
	# the embedded popup. Select its semantic item explicitly, rather than
	# claiming native popup keyboard automation. All scene/recovery input below
	# uses parsed engine events with synchronized OS cursor position.
	await click(editor.target_choice)
	var popup: PopupMenu = editor.target_choice.get_popup()
	check(popup.visible, "parsed GUI click opens the actual targeting dropdown")
	popup.hide()
	editor.target_choice.select(editor.TargetMode.SURFACE)
	editor.target_choice.item_selected.emit(editor.TargetMode.SURFACE)
	await frames(3)
	check(editor.targeting_mode == editor.TargetMode.SURFACE and editor.section_toggle.button_pressed,
		"selecting Surface keeps the explicit cutaway geometry")
	var cell := Vector3i(VoxelCodec.GRID / 2, VoxelCodec.GRID / 5 + 1, VoxelCodec.GRID / 2)
	var hover := point(cell)
	move_to(hover)
	await preview()
	print("CUTAWAY_BLOCKED_PICK ", editor.pick_cache)
	check(not editor.pick_cache.get("valid", true) and editor._surface_block_reason() == "section" and editor.section_action.is_visible_in_tree(),
		"default water cut face produces explicit blocked feedback and visible recovery")
	check(editor.section_action.get_global_rect().end.x <= 1280 and editor.tools_panel.size.x <= 430,
		"Cutaway and recovery controls fit a 1280×800 laptop window (recovery ends at %.0f, panel %.0f wide)" % [editor.section_action.get_global_rect().end.x, editor.tools_panel.size.x])
	await capture_pointer("blocked-cut-face")
	var selected_axis: int = editor.axis
	var selected_depth: int = editor.depth
	await click(editor.section_action)
	check(not editor.section and not editor.section_toggle.button_pressed and await read() == original,
		"actual recovery click shows the whole world without changing any packed material")
	check(editor.axis == selected_axis and editor.depth == selected_depth and editor.targeting_mode == editor.TargetMode.SURFACE and not editor.testing,
		"recovery preserves exact plane, surface tool and Build phase")
	move_to(hover)
	await preview()
	print("WHOLE_WORLD_PICK ", editor.pick_cache)
	check(editor.pick_cache.get("valid", false) and editor.marker.visible, "same real hover obtains a usable whole-world surface preview")
	var accepted_cell: Vector3i = editor.pick_cache.get("target", Vector3i.ZERO)
	var paint_element: int = editor.element
	mouse(true)
	await frames(3)
	mouse(false)
	await settled()
	var painted := await read()
	check(painted != original and id_at(painted, accepted_cell) == paint_element and editor.undo_history.size() == 1,
		"parsed surface stroke after recovery changes the GPU at its visible target and records authored Undo")
	check(preserved_walls(original, painted), "recovered additive stroke preserves every original container wall")
	await capture_pointer("accepted-surface-paint")
	await click(editor.undo_button)
	await settled()
	check(await read() == original, "recovered surface stroke undoes exactly")
	await click(editor.section_toggle)
	key(KEY_X)
	move_to(hover)
	await preview()
	check(editor.section and editor.erase and editor.pick_cache.get("valid", false) and not editor.section_action.visible,
		"Erase on the original cut face remains valid without demanding whole-world recovery")
	var erase_hit: Vector3i = editor.pick_cache.get("hit", Vector3i.ZERO)
	mouse(true)
	await frames(3)
	mouse(false)
	await settled()
	check(id_at(await read(), erase_hit) == Elements.Id.AIR, "parsed cut-face erase removes the intended material")
	await click(editor.undo_button)
	await settled()
	check(await read() == original, "cut-face erasing undoes exact seeds, amounts and flags")
	# A view command during a paused live hold must cancel that old source.
	await click(editor.section_toggle)
	key(KEY_X)
	await click(editor.material_buttons[Elements.Id.SAND])
	await click(editor.play_button)
	await settled()
	await click(editor.pause_button)
	check(editor.testing and clock.paused, "same scene enters paused Test for source-boundary validation")
	move_to(hover)
	await preview()
	var source_was_valid: bool = editor.pick_cache.get("valid", false)
	mouse(true) # A new gesture intentionally invalidates its old hover preview.
	await frames(2)
	check(editor.painting and editor.live_emitter_signature != 0 and editor.stroke_element == Elements.Id.SAND and source_was_valid, "paused primary hold creates a live source with the whole-world view")
	var sand_before: int = sim.histogram(await read())[Elements.Id.SAND]
	# Programmatic toggle of the real control models a view command arriving
	# while the primary button is held; the recovery itself above used GUI clicks.
	editor.section_toggle.button_pressed = true
	check(not editor.painting and editor.live_emitter_signature == 0 and editor.testing and clock.paused,
		"Cutaway view command terminates the source while preserving paused Test")
	mouse(false)
	await preview()
	await capture_pointer("paused-test-cutaway")
	check(editor.pause_button.get_global_rect().end.y < editor.tools_panel.get_global_rect().end.y and editor.status.get_global_rect().end.y <= editor.tools_panel.get_global_rect().end.y - 4,
		"Test controls and full status remain inside the 1280×800 sidebar with cutaway feedback (status ends at %.0f, panel at %.0f)" % [editor.status.get_global_rect().end.y, editor.tools_panel.get_global_rect().end.y])
	await click(editor.step_button)
	var after_step := await read()
	check(sim.histogram(after_step)[Elements.Id.SAND] == sand_before,
		"next authoritative tick receives no stale pre-cutaway live stamp")
	await click(editor.play_button)
	await settled()
	check(not editor.testing and clock.paused and await read() == original, "Return restores authored material after view changes and live inspection")
	_restore_input()
	await frames(2)
	print("Surface feedback GPU: %d checks, %d failures; evidence=%s" % [checks, failures, output_dir])
	quit(1 if failures else 0)
