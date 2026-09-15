extends SceneTree
## Archive v2 through the real editor and GPU: temperatures save and open
## exactly, Test saves the authored temperatures, Return and regional Undo
## restore them, and a version-1 file opens with the same default
## temperatures as a fresh build.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/archives_thermal_gpu.gd -- grid=128
var editor: Node3D
var sim: Node3D
var panel: Node
var checks := 0
var failures := 0
var out_dir := "/tmp/editing-gpu/archives-thermal"

func _initialize() -> void:
	create_timer(100.0).timeout.connect(func():
		push_error("Archive thermal GPU watchdog expired")
		quit(1))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("output_dir="): out_dir = arg.trim_prefix("output_dir=")
	DirAccess.make_dir_recursive_absolute(out_dir)
	call_deferred("run")

func check(ok: bool, label: String) -> void:
	checks += 1
	print("%s: %s" % ["ok" if ok else "FAIL", label])
	if not ok:
		failures += 1

func read() -> PackedByteArray:
	sim.request_readback(func(_bytes): pass)
	return await sim.readback_ready

func read_thermal() -> PackedByteArray:
	sim.request_thermal_readback()
	return await sim.thermal_ready

func wait_for_file() -> void:
	while panel.operation != "":
		await process_frame
	await process_frame

func settled() -> void:
	while editor.capturing or not editor._queued_editor_action.is_empty():
		await process_frame
	await process_frame

func write_v1(path: String, bytes: PackedByteArray, grid: int) -> void:
	var header := {"version": 1, "kind": "authored", "grid": grid, "cell_size_m": 0.01, "schema": WorldArchive.SCHEMA_V1,
		"codec": "zstd", "size": bytes.size(), "sha256": WorldArchive._hash(bytes)}
	var json := JSON.stringify(header).to_utf8_buffer()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(WorldArchive.MAGIC.to_ascii_buffer())
	file.store_32(json.size())
	file.store_buffer(json)
	file.store_buffer(bytes.compress(FileAccess.COMPRESSION_ZSTD))
	file.close()

func run() -> void:
	editor = load("res://scenes/discovery/interaction.tscn").instantiate()
	root.add_child(editor)
	current_scene = editor
	sim = editor.sim
	# The simulator connected to the clock in its own _ready; detach it so ticks
	# happen only where this test asks for them.
	if root.get_node("TimeController").ticks_requested.is_connected(sim.request_ticks):
		root.get_node("TimeController").ticks_requested.disconnect(sim.request_ticks)
	panel = editor.archive_panel
	for i in 10:
		await RenderingServer.frame_post_draw
	var n := VoxelCodec.GRID
	var voxels := await read()
	var defaults := await read_thermal()
	check(defaults.size() == n * n * n * 8, "the fresh build has a thermal layer of the expected size")
	# A hand-made temperature field: the water is warm, one corner of the wall is hot.
	var custom := defaults.duplicate()
	for i in n * n * n:
		var id := voxels[i * 4]
		if id == Elements.Id.WATER:
			custom.encode_float(i * 8, 342.15)
		elif id == Elements.Id.WALL and i % 3 == 0:
			custom.encode_float(i * 8, 800.0)
			custom.encode_float(i * 8 + 4, 0.25)
	check(custom != defaults and editor.replace_authored(voxels, custom), "the editor accepts an explicit thermal layer with a build")
	await process_frame
	check(await read_thermal() == custom and await read() == voxels, "explicit temperatures reach the GPU exactly")
	var path := out_dir.path_join("thermal-%s.p3d" % Time.get_ticks_usec())
	panel.save_to_path(path)
	await wait_for_file()
	var saved: Dictionary = WorldArchive.load_authored(path, n)
	check(saved.ok and saved.bytes == voxels and saved.thermal == custom and saved.header.version == 2, "Build save writes both layers exactly as version 2")
	check(not editor.document.is_dirty() and editor.document.path == path, "the saved build is clean and named")
	editor.run_or_restore()
	await settled()
	check(editor.testing and editor.build_thermal == custom and editor.build_snapshot == voxels, "entering Test snapshots the authored temperatures")
	sim.request_ticks(12)
	var live := await read()
	var live_thermal := await read_thermal()
	check(live != voxels or live_thermal != custom, "the live experiment has evolved")
	panel.save_to_path(path)
	await wait_for_file()
	saved = WorldArchive.load_authored(path, n)
	check(saved.ok and saved.bytes == voxels and saved.thermal == custom, "saving during Test stores the authored temperatures, not the live ones")
	editor.run_or_restore()
	await settled()
	check(not editor.testing and await read() == voxels and await read_thermal() == custom, "Return restores the authored temperatures exactly")
	# Regional Undo restores both layers.
	editor._begin_authored_edit()
	var centers: Array[Vector3i] = [Vector3i(n / 2, n * 3 / 4, n / 2)]
	sim.record_stroke(editor.active_transaction, centers, 3, Elements.Id.SAND, sim.BrushMode.ONLY_AIR, 42)
	editor._end_stroke()
	await settled()
	check(await read() != voxels and editor.undo_history.size() == 1, "an authored stroke changed the build")
	editor.undo_edit()
	await settled()
	check(await read() == voxels and await read_thermal() == custom, "Undo restores voxels and temperatures exactly")
	# Opening the version-2 file restores both layers.
	editor.replace_authored(WorldBuilder.empty().to_byte_array())
	await process_frame
	panel.open_path(path)
	await wait_for_file()
	check(await read() == voxels and await read_thermal() == custom and editor.document.path == path and not editor.document.is_dirty(), "opening a version-2 file restores voxels and temperatures exactly")
	# A version-1 file opens with the same defaults a fresh build gets.
	editor.replace_authored(voxels)
	await process_frame
	var fresh := await read_thermal()
	var legacy := out_dir.path_join("legacy-%s.p3d" % Time.get_ticks_usec())
	write_v1(legacy, voxels, n)
	editor.replace_authored(WorldBuilder.empty().to_byte_array())
	await process_frame
	panel.open_path(legacy)
	await wait_for_file()
	check(await read() == voxels and await read_thermal() == fresh and editor.document.path == legacy, "a version-1 file opens with default temperatures identical to a fresh build")
	check(fresh != custom, "default temperatures differ from the authored ones, so the previous check is meaningful")
	panel.save_to_path(legacy)
	await wait_for_file()
	saved = WorldArchive.load_authored(legacy, n)
	check(saved.ok and saved.header.version == 2 and saved.thermal == fresh, "saving an opened version-1 world upgrades it to version 2 with its actual temperatures")
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(legacy)
	editor.queue_free()
	await process_frame
	print("ARCHIVES_THERMAL_CHECKS %d FAILURES %d" % [checks, failures])
	quit(1 if failures else 0)
