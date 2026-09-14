extends SceneTree
const Archive := preload("res://scripts/editor/world_archive.gd")
var checks := 0
var failures := 0
var folder := "user://archive-tests-%s" % Time.get_ticks_usec()

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func write_header(path: String, header: Dictionary, payload: PackedByteArray) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	var json := JSON.stringify(header).to_utf8_buffer()
	file.store_buffer(Archive.MAGIC.to_ascii_buffer())
	file.store_32(json.size())
	file.store_buffer(json)
	file.store_buffer(payload)
	file.close()

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var path := folder.path_join("construction.p3d")
	var bytes := PackedByteArray()
	bytes.resize(16 * 16 * 16 * 4)
	for i in bytes.size():
		bytes[i] = (i * 17 + i / 4) % 256
	for offset in range(0, bytes.size(), 4):
		bytes[offset] = (offset / 4) % Elements.count()
	var saved := Archive.save_authored(path, bytes, 16)
	check(saved.ok, "authored save is written")
	var loaded := Archive.load_authored(path, 16)
	check(loaded.ok and loaded.bytes == bytes, "all packed material, seed, amount and flag bytes round-trip")
	check(loaded.header.kind == "authored" and loaded.header.schema == Archive.SCHEMA, "archive declares authored state and schema")
	check(not Archive.load_authored(path, 128).ok, "world from another session size is rejected before upload")
	check(not Archive.save_authored(path, bytes, 128).ok, "invalid snapshot size is rejected")
	check(Archive.load_authored(path, 16).bytes == bytes, "failed save leaves previous file intact")
	bytes[123] = 99
	check(Archive.save_authored(path, bytes, 16).ok and Archive.load_authored(path, 16).bytes == bytes, "successful replacement is exact")
	check(not Archive.load_authored(folder.path_join("missing.p3d")).ok, "missing file returns a readable failure")
	var bad_path := folder.path_join("bad.p3d")
	var file := FileAccess.open(bad_path, FileAccess.WRITE)
	file.store_buffer("bad!".to_ascii_buffer())
	file.close()
	check(not Archive.load_authored(bad_path).ok, "truncated or unrelated file rejected")
	file = FileAccess.open(bad_path, FileAccess.WRITE)
	file.store_buffer(Archive.MAGIC.to_ascii_buffer())
	file.store_32(100000000)
	file.store_8(0)
	file.close()
	check(not Archive.load_authored(bad_path).ok, "oversized header rejected before allocation")
	var header: Dictionary = saved.header.duplicate()
	header.version = 2
	write_header(bad_path, header, bytes.compress(FileAccess.COMPRESSION_ZSTD))
	check(not Archive.load_authored(bad_path).ok, "unknown schema version rejected")
	header = saved.header.duplicate()
	header.grid = 1000000000
	write_header(bad_path, header, PackedByteArray([1]))
	check(not Archive.load_authored(bad_path).ok, "unbounded dimensions rejected before allocation")
	header = saved.header.duplicate()
	write_header(bad_path, header, bytes.compress(FileAccess.COMPRESSION_ZSTD))
	check(not Archive.load_authored(bad_path).ok, "checksum detects changed payload")
	var unsupported := bytes.duplicate()
	unsupported[unsupported.size() - 4] = 255
	header.sha256 = Archive._hash(unsupported)
	write_header(bad_path, header, unsupported.compress(FileAccess.COMPRESSION_ZSTD))
	var rejected := Archive.load_authored(bad_path)
	check(not rejected.ok and rejected.error.contains("unsupported material"), "checksum-valid unknown material is rejected before GPU upload")
	check(not Archive.save_authored(path, unsupported, 16).ok and Archive.load_authored(path, 16).bytes == bytes, "unsupported material cannot replace an existing valid save")
	# Files belong solely to this test's unique directory.
	for name in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(folder.path_join(name))
	DirAccess.remove_absolute(folder)
	print("World archive: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
