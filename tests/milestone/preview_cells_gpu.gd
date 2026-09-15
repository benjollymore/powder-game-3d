extends SceneTree
## Ghost preview (docs/milestone/placement-brief.md contract 6): for a
## stationary pointer the previewed cell set equals the applied stamp's
## changed cells, on the workplane and on a picked surface, for all three
## shapes, add and erase. Uses the real editor scene and parsed input.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/preview_cells_gpu.gd -- grid=128 output_dir=/tmp/preview-cells
const BrushScript := preload("res://scripts/sim/brush.gd")
var editor: Node3D
var sim: Node3D
var checks := 0
var failures := 0
var output_dir := "/tmp/preview-cells"
var pointer := Vector2.ZERO
var held := false
var input_configured := false
var original_cursor := Vector2i.ZERO
var original_accumulation := true

func _initialize() -> void:
	create_timer(100.0).timeout.connect(func():
		push_error("Preview cells watchdog expired")
		_restore_input()
		quit(1))
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])
	if not ok:
		failures += 1

func frames(count: int = 2) -> void:
	for i in count:
		await process_frame

func move_to(position: Vector2) -> void:
	Input.warp_mouse(position)
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = position - pointer
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	pointer = position
	Input.parse_input_event(event)

func mouse(down: bool) -> void:
	held = down
	var event := InputEventMouseButton.new()
	event.position = pointer
	event.global_position = pointer
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if held else 0
	event.pressed = down
	Input.parse_input_event(event)

func read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func point(cell: Vector3i) -> Vector2:
	return editor.camera.unproject_position(sim.to_global((Vector3(cell) + Vector3.ONE * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5))

func changed_ids(before: PackedByteArray, after: PackedByteArray) -> Dictionary:
	var n: int = VoxelCodec.GRID
	var cells := {}
	for i in range(0, before.size(), 4):
		if before[i] != after[i]:
			var cell := i / 4
			cells[Vector3i(cell % n, (cell / n) % n, cell / (n * n))] = true
	return cells

func same_set(cells: Array, set: Dictionary) -> bool:
	if cells.size() != set.size():
		return false
	for cell in cells:
		if not set.has(cell):
			return false
	return true

func settled() -> void:
	while editor.capturing or not editor._queued_editor_action.is_empty():
		await process_frame
	await frames(2)

## Wait until the preview for the shown target has arrived (pending cleared and a set shown).
func preview_ready() -> void:
	for i in 40:
		await process_frame
		if editor.target.x >= 0 and not editor.preview_pending and editor.preview_signature != 0:
			return

func _restore_input() -> void:
	if not input_configured:
		return
	if held:
		mouse(false)
	Input.use_accumulated_input = original_accumulation
	DisplayServer.warp_mouse(original_cursor - DisplayServer.window_get_position(root.get_window_id()))
	input_configured = false

func run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="):
			output_dir = arg.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(output_dir)
	original_cursor = DisplayServer.mouse_get_position()
	original_accumulation = Input.use_accumulated_input
	input_configured = true
	Input.use_accumulated_input = false
	root.size = Vector2i(1280, 800)
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	sim = editor.sim
	await frames(12)
	var n: int = VoxelCodec.GRID
	# A wall slab facing +z for the surface cases, below the workplane targets.
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(n / 4, n / 4, n / 2 - 20), Vector3i(3 * n / 4, 3 * n / 4, n / 2 - 19), Elements.Id.WALL)
	sim.upload(data.to_byte_array())
	await frames(6)
	editor._set_target_mode(editor.TargetMode.PLANE)
	editor.radius_input.value = 2
	var names := ["sphere", "cube", "disc"]
	var before := await read()
	var stamp_cells := []
	for shape in 3:
		editor._choose_material(Elements.Id.SAND)
		editor.shape = shape
		editor.shape_overridden = true
		var cell := Vector3i(n / 2 - 24 + shape * 12, n / 2, editor.depth)
		move_to(point(cell))
		await preview_ready()
		var previewed: Array = editor.preview_cells().duplicate()
		var shown_target: Vector3i = editor.target
		check(shown_target.x >= 0 and not previewed.is_empty(), "%s workplane preview shows a target and a non-empty cell set" % names[shape])
		mouse(true)
		await frames(1)
		mouse(false)
		await settled()
		var after := await read()
		var changed := changed_ids(before, after)
		check(same_set(previewed, changed), "%s workplane stamp changes exactly the previewed cells (%d previewed, %d changed)" % [names[shape], previewed.size(), changed.size()])
		stamp_cells.append(previewed.size())
		before = after
	# Erase preview over the sand just placed: only occupied cells are previewed and erased.
	editor.erase = true
	editor.shape = BrushScript.Shape.CUBE
	var erase_cell := Vector3i(n / 2 - 24, n / 2, editor.depth)
	move_to(point(erase_cell) + Vector2(1, 0))
	await preview_ready()
	var erase_preview: Array = editor.preview_cells().duplicate()
	check(not erase_preview.is_empty() and erase_preview.size() < 125, "erase preview lists only occupied cells of the cube")
	mouse(true)
	await frames(1)
	mouse(false)
	await settled()
	var after_erase := await read()
	check(same_set(erase_preview, changed_ids(before, after_erase)), "erase stamp removes exactly the previewed cells (%d)" % erase_preview.size())
	before = after_erase
	editor.erase = false
	# Surface mode: the preview follows the live pick target on the slab.
	editor._set_target_mode(editor.TargetMode.SURFACE)
	editor.section_toggle.button_pressed = false
	await frames(3)
	for shape in 3:
		editor.shape = shape
		var cell := Vector3i(n / 2 - 24 + shape * 12, n / 2, n / 2 - 19)
		move_to(point(cell))
		await preview_ready()
		var previewed: Array = editor.preview_cells().duplicate()
		check(editor.pick_cache.get("valid", false) and not previewed.is_empty(), "%s surface preview follows a valid pick" % names[shape])
		mouse(true)
		await frames(1)
		mouse(false)
		await settled()
		var after := await read()
		var changed := changed_ids(before, after)
		check(same_set(previewed, changed), "%s surface stamp changes exactly the previewed cells (%d previewed, %d changed)" % [names[shape], previewed.size(), changed.size()])
		var walls := true
		for i in range(0, after.size(), 4):
			if data[i / 4] & 0xFF == Elements.Id.WALL and after[i] != Elements.Id.WALL:
				walls = false
		check(walls, "%s surface stamp preserves the slab" % names[shape])
		before = after
	# Moving the pointer keeps a preview visible every frame (never hidden by motion).
	var hidden_frames := 0
	for step in 30:
		move_to(point(Vector3i(n / 2 - 20 + step, n / 2 + 10, n / 2 - 19)))
		await process_frame
		if editor.target.x >= 0 and not editor.preview_mesh.visible:
			hidden_frames += 1
	check(hidden_frames == 0, "preview stays visible while the pointer moves over a valid target (%d hidden frames)" % hidden_frames)
	_restore_input()
	await frames(2)
	var file := FileAccess.open(output_dir.path_join("preview_cells.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks": checks, "failures": failures, "stamp_cells": stamp_cells}, "\t"))
	file.close()
	print("PREVIEW_CELLS_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
