extends SceneTree
var failures := 0
var checks := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1
func run() -> void:
	root.size = Vector2i(1280, 800)
	var editor = load("res://tests/milestone/surface_feedback_lab.gd").new()
	root.add_child(editor)
	await process_frame
	editor._set_target_mode(editor.TargetMode.SURFACE)
	check(editor.section and editor.section_toggle.button_pressed and editor.section_toggle.is_visible_in_tree() and not editor.advanced_tools.visible,
		"Surface preserves the explicit cutaway state and exposes it with advanced tools closed")
	editor.pick_cache = {"valid": false, "hit": Vector3i(64, 26, 64), "normal": Vector3i.BACK, "target": Vector3i(64, 26, 68)}
	editor._refresh_target_controls()
	check(editor._surface_block_reason() == "section" and editor.section_action.visible and editor._surface_feedback().contains("Cutaway"),
		"actual cut-face rejection explains its cause and exposes whole-world recovery")
	editor.pick_cache.valid = true
	editor.pick_cache.target = editor.pick_cache.hit
	editor.erase = true
	editor._refresh_target_controls()
	check(not editor.section_action.visible and editor._surface_feedback().contains("erase"), "valid cut-face erasing is not misreported as blocked")
	editor.pick_cache = {"valid": false, "hit": Vector3i(VoxelCodec.GRID - 1, 26, 64), "normal": Vector3i.RIGHT, "target": Vector3i(VoxelCodec.GRID + 2, 26, 64)}
	check(editor._surface_block_reason() == "boundary", "world-boundary rejection does not offer an ineffective cutaway recovery")
	editor.pick_cache = {"valid": false, "hit": Vector3i(-1, -1, -1)}
	check(editor._surface_block_reason() == "miss" and editor._surface_feedback().contains("No surface"), "empty-space miss gets distinct feedback")
	editor.pick_cache = {"valid": false, "hit": Vector3i(64, 26, 64), "normal": Vector3i.ZERO, "target": Vector3i(64, 26, 64)}
	check(editor._surface_block_reason() == "inside", "camera inside material suggests orbiting instead of unrelated plane placement")
	editor.pick_cache.clear()
	editor.pick_pending = true
	check(editor._surface_feedback() == "Finding surface…", "pending preview is distinguished from a rejected target")
	editor.testing = true
	editor.painting = true
	editor.live_emitter_signature = 1
	var plane_axis: int = editor.axis
	var plane_depth: int = editor.depth
	var paused: bool = root.get_node("TimeController").paused
	editor._set_section(false)
	check(not editor.painting and editor.sim.cancelled == 1 and editor.sim.finished == 0,
		"view change cancels an active live source instead of completing a stale click")
	check(editor.testing and root.get_node("TimeController").paused == paused and editor.axis == plane_axis and editor.depth == plane_depth and editor.targeting_mode == editor.TargetMode.SURFACE,
		"explicit recovery preserves phase, exact plane coordinates and surface mode")
	check(not editor.section and not editor.section_toggle.button_pressed and not editor.section_action.visible and editor.pick_cache.is_empty(),
		"whole-world recovery synchronizes visible state and invalidates old picks")
	editor.queue_free()
	await process_frame
	print("Surface feedback CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
