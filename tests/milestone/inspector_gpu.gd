extends "res://tests/milestone/editor_workflow_gpu.gd"
## Hover inspector over the real editor: the status line names the cell under
## the pointer with its temperature and fill, stays quiet over the UI, over
## empty air and while painting, and never issues a full readback.
func read_thermal() -> PackedByteArray:
	sim.request_thermal_readback()
	return await sim.thermal_ready
func probe_settled() -> void:
	for i in 6:
		await process_frame
	while editor.probe_pending:
		await process_frame
	await frames(2)
func run() -> void:
	output_dir = "/tmp/editing-gpu/inspector"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): output_dir = arg.trim_prefix("output_dir=")
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
	# The simulator connected to the clock in its own _ready; detach it so ticks
	# happen only where this test asks for them.
	if root.get_node("TimeController").ticks_requested.is_connected(sim.request_ticks):
		root.get_node("TimeController").ticks_requested.disconnect(sim.request_ticks)
	clock = root.get_node("TimeController")
	await frames(12)
	var n := VoxelCodec.GRID
	# Warm water block and a hot sand block in open air, cutaway off so the
	# nearest face along the pointer ray is the one inspected.
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(n / 4, n / 4, n / 4), Vector3i(n / 2, n / 2, n * 3 / 4), Elements.Id.WATER)
	WorldBuilder.fill_box(data, Vector3i(n * 5 / 8, n / 4, n / 4), Vector3i(n * 7 / 8, n / 2, n * 3 / 4), Elements.Id.SAND)
	var voxels := data.to_byte_array()
	var thermal := PackedFloat32Array()
	thermal.resize(n * n * n * 2)
	for i in n * n * n:
		var id := voxels[i * 4]
		thermal[i * 2] = 342.15 if id == Elements.Id.WATER else (600.0 if id == Elements.Id.SAND else 293.15)
	editor.replace_authored(voxels, thermal.to_byte_array())
	editor._set_section(false)
	await frames(4)
	var readbacks := 0
	sim.readback_ready.connect(func(_bytes): readbacks += 1)
	var water := Vector3i(n * 3 / 8, n * 3 / 8, n / 2)
	move_to(point(water))
	await probe_settled()
	check(editor.probe_text == "Water · 69 °C · full", "hovering the water block reads 'Water · 69 °C · full' (got '%s')" % editor.probe_text)
	var sand := Vector3i(n * 3 / 4, n * 3 / 8, n / 2)
	move_to(point(sand))
	await probe_settled()
	check(editor.probe_text == "Sand · 327 °C", "hovering the sand block reads 'Sand · 327 °C' (got '%s')" % editor.probe_text)
	check(readbacks == 0, "inspecting never triggers a full world readback")
	move_to(point(Vector3i(n * 9 / 16, n * 15 / 16, n / 2)))
	await probe_settled()
	check(editor.probe_text.is_empty(), "empty air under the pointer reads nothing")
	move_to(Vector2(120, 120))
	await probe_settled()
	check(editor.probe_text.is_empty(), "the inspector is quiet over the tools panel")
	move_to(point(water))
	await frames(1)
	mouse(true)
	await frames(3)
	check(editor.painting and editor.probe_text.is_empty(), "the inspector is quiet while painting")
	mouse(false)
	await settled()
	await probe_settled()
	check(editor.probe_text.begins_with("Water"), "the inspector resumes after the stroke")
	# Cutaway: the probe follows the visible surface contract (nearest material).
	editor._set_section(true)
	await probe_settled()
	check(editor.probe_text.begins_with("Water") or editor.probe_text.is_empty(), "cutaway does not produce a stale or foreign reading")
	await capture("inspector-water")
	_restore_input()
	await frames(2)
	print("INSPECTOR_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
