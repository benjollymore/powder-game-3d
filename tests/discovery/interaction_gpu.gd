extends SceneTree
## Visible-window acceptance harness; use grid=128 for bounded discovery cost.
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
var lab: Node3D
var failures := 0
var checks := 0
var output_dir := "user://interaction-regression"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="):
			output_dir = arg.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_dir))
	create_timer(90.0).timeout.connect(func(): quit(1))
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	lab = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(lab)
	_run()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func read() -> PackedByteArray:
	await process_frame
	lab.sim.request_readback(func(_bytes): pass)
	return await lab.sim.readback_ready

func id_at(bytes: PackedByteArray, p: Vector3i) -> int:
	return bytes[VoxelCodec.index(p.x, p.y, p.z) * 4]

func _run() -> void:
	for i in 8:
		await process_frame
	var n := VoxelCodec.GRID
	var before := await read()
	check(before.size() == n * n * n * 4, "production GPU volume readback")
	# Exact targeting through the actual camera projection on all three planes.
	for axis in 3:
		lab.set_plane(axis)
		var cell := Vector3i(n / 2, n / 2, n / 2)
		var world: Vector3 = lab.sim.global_transform * ((Vector3(cell) + Vector3.ONE * 0.5) / n - Vector3.ONE * 0.5)
		check(lab._target_at(lab.camera.unproject_position(world)) == cell, "camera ray picks exact plane cell on axis %d" % axis)
	lab.set_plane(2)
	var points := Geometry.stroke(Vector3i(n / 5, n / 2, n / 2), Vector3i(n * 4 / 5, n / 2 + 8, n / 2))
	lab.sim.paint_stroke(points, 0, Elements.Id.SAND)
	var painted := await read()
	var connected := true
	for p in points:
		connected = connected and id_at(painted, p) != Elements.Id.AIR
	check(connected, "single-cell fast diagonal stroke leaves no gaps across tank walls")
	var walls_intact := true
	for i in range(0, before.size(), 4):
		if before[i] == Elements.Id.WALL and painted[i] != Elements.Id.WALL:
			walls_intact = false
	check(walls_intact, "ONLY_AIR stroke preserves every original wall cell")
	# Region UI operation crosses the wall and adds water, then its undo restores
	# all packed bytes exactly, including original element seed and amount.
	lab._select_corner(Vector3i(n / 5, n / 2, n / 2 - 2))
	lab._select_corner(Vector3i(n / 3, n / 2 + 4, n / 2 + 2))
	lab.element = Elements.Id.WATER
	lab.fill_selection()
	while lab.capturing:
		await process_frame
	var filled := await read()
	check(id_at(filled, Vector3i(n / 5, n / 2, n / 2 - 2)) == Elements.Id.WATER, "two-corner UI region operation reaches inclusive corner")
	walls_intact = true
	for i in range(0, before.size(), 4):
		if before[i] == Elements.Id.WALL and filled[i] != Elements.Id.WALL:
			walls_intact = false
	check(walls_intact, "region fill preserves every original wall cell")
	lab.undo_edit()
	while lab.capturing:
		await process_frame
	check(await read() == painted, "undo region restores packed voxel bytes exactly")
	# Simulate a brush gesture while its undo snapshot is still pending; changing
	# palette/radius before readback must not rewrite that gesture's metadata.
	var cell := Vector3i(n / 2, n * 3 / 4, n / 2)
	var world: Vector3 = lab.sim.global_transform * ((Vector3(cell) + Vector3.ONE * 0.5) / n - Vector3.ONE * 0.5)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = lab.camera.unproject_position(world)
	lab.element = Elements.Id.SAND
	lab.radius = 0
	lab._unhandled_input(press)
	lab._end_stroke()
	lab.element = Elements.Id.WATER
	lab.radius = 3
	while lab.capturing:
		await process_frame
	var gesture := await read()
	check(id_at(gesture, cell) == Elements.Id.SAND, "pending gesture retains original material across palette change")
	check(id_at(gesture, cell + Vector3i.RIGHT) == Elements.Id.AIR, "pending gesture retains original single-cell radius")
	lab.undo_edit()
	while lab.capturing:
		await process_frame
	check(await read() == painted, "undo brush gesture restores packed voxel bytes exactly")
	lab.section = false
	lab._update_plane()
	check(await read() == painted, "section toggle leaves all simulation voxel bytes unchanged")
	lab.section = true
	lab._update_plane()
	lab.run_or_restore()
	while lab.capturing:
		await process_frame
	for i in 60:
		await process_frame
	var running := await read()
	check(running != painted, "Run actually advances material simulation")
	# Live paint now belongs to simulation ticks, including a click released
	# before its first tick. Pausing must preserve state until a tick is requested.
	root.get_node("TimeController").paused = true
	var before_live := await read()
	lab.element = Elements.Id.SAND
	lab.radius = 0
	lab._unhandled_input(press)
	var release := press.duplicate()
	release.pressed = false
	lab._input(release)
	check(await read() == before_live, "released live click does not mutate a paused world before a tick")
	lab.sim.request_ticks(1)
	var after_live := await read()
	check(lab.sim.histogram(after_live)[Elements.Id.SAND] == lab.sim.histogram(before_live)[Elements.Id.SAND] + 1,
		"released live click adds one grain on the next simulation tick")
	lab.run_or_restore()
	check(await read() == painted, "Return to build restores authored voxel bytes exactly")
	check(root.get_node("TimeController").paused, "Return to build freezes simulation")
	for i in 8:
		await process_frame
	var path := output_dir.path_join("interaction-front.png")
	check(root.get_texture().get_image().save_png(path) == OK, "front section screenshot saved")
	lab.yaw = 0.65
	lab.pitch = -0.4
	lab._update_camera()
	for i in 8:
		await process_frame
	check(root.get_texture().get_image().save_png(output_dir.path_join("interaction-angle.png")) == OK, "angled section screenshot saved")
	print("Interaction GPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
