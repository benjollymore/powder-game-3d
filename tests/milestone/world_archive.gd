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

func v2_header(grid: int, bytes: PackedByteArray, thermal: PackedByteArray) -> Dictionary:
	var combined := bytes.duplicate()
	combined.append_array(thermal)
	return {"version": 2, "kind": "authored", "grid": grid, "cell_size_m": 0.01, "schema": Archive.SCHEMA, "codec": "zstd",
		"size": combined.size(), "sha256": Archive._hash(combined),
		"layers": [{"name": "voxels", "format": "rgba8", "size": bytes.size(), "sha256": Archive._hash(bytes)},
			{"name": "thermal", "format": "rg32f", "size": thermal.size(), "sha256": Archive._hash(thermal)}]}

func v2_payload(bytes: PackedByteArray, thermal: PackedByteArray) -> PackedByteArray:
	var combined := bytes.duplicate()
	combined.append_array(thermal)
	return combined.compress(FileAccess.COMPRESSION_ZSTD)

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(folder)
	var path := folder.path_join("construction.p3d")
	var cells := 16 * 16 * 16
	var bytes := PackedByteArray()
	bytes.resize(cells * 4)
	for i in bytes.size():
		bytes[i] = (i * 17 + i / 4) % 256
	for offset in range(0, bytes.size(), 4):
		bytes[offset] = (offset / 4) % Elements.count()
	var temps := PackedFloat32Array()
	temps.resize(cells * 2)
	for i in cells:
		temps[i * 2] = 250.0 + (i % 97) * 3.5
		temps[i * 2 + 1] = float(i % 5) * 0.2
	var thermal := temps.to_byte_array()
	var saved := Archive.save_authored(path, bytes, 16, thermal)
	check(saved.ok, "authored save is written")
	var loaded := Archive.load_authored(path, 16)
	check(loaded.ok and loaded.bytes == bytes, "all packed material, seed, amount and flag bytes round-trip")
	check(loaded.thermal == thermal, "every temperature and latent float round-trips exactly")
	check(loaded.header.version == 2 and loaded.header.kind == "authored" and loaded.header.schema == Archive.SCHEMA and loaded.header.layers.size() == 2,
		"archive declares authored state, the two-layer schema and per-layer checksums")
	check(not Archive.load_authored(path, 128).ok, "world from another session size is rejected before upload")
	check(not Archive.save_authored(path, bytes, 128, thermal).ok, "invalid snapshot size is rejected")
	check(not Archive.save_authored(path, bytes, 16).ok and not Archive.save_authored(path, bytes, 16, thermal.slice(0, 64)).ok, "a missing or short temperature layer cannot be saved")
	var nan_thermal := thermal.duplicate()
	nan_thermal.encode_float(8, NAN)
	check(not Archive.save_authored(path, bytes, 16, nan_thermal).ok and Archive.load_authored(path, 16).bytes == bytes, "non-finite temperatures are rejected and the previous file survives")
	bytes[123] = 99
	check(Archive.save_authored(path, bytes, 16, thermal).ok and Archive.load_authored(path, 16).bytes == bytes, "successful replacement is exact")
	# Version 1 files carry voxels only and load with an empty thermal layer.
	var legacy_path := folder.path_join("legacy.p3d")
	var legacy_header := {"version": 1, "kind": "authored", "grid": 16, "cell_size_m": 0.01, "schema": Archive.SCHEMA_V1, "codec": "zstd",
		"size": bytes.size(), "sha256": Archive._hash(bytes)}
	write_header(legacy_path, legacy_header, bytes.compress(FileAccess.COMPRESSION_ZSTD))
	var legacy := Archive.load_authored(legacy_path, 16)
	check(legacy.ok and legacy.bytes == bytes and legacy.thermal.is_empty() and legacy.header.version == 1, "a version-1 world loads its exact voxels with no thermal layer")
	var defaults := Archive.default_thermal(bytes)
	check(defaults.size() == cells * 8 and is_equal_approx(defaults.decode_float(0), Elements.thermal(bytes[0], "initial_temp")) and is_equal_approx(defaults.decode_float(8 * 5), Elements.thermal(bytes[4 * 5], "initial_temp")) and defaults.decode_float(4) == 0.0,
		"default temperatures follow each cell's element with no latent progress")
	legacy_header.sha256 = "0".repeat(64)
	write_header(legacy_path, legacy_header, bytes.compress(FileAccess.COMPRESSION_ZSTD))
	check(not Archive.load_authored(legacy_path, 16).ok, "a damaged version-1 world is still rejected")
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
	var header: Dictionary = v2_header(16, bytes, thermal)
	header.version = 3
	write_header(bad_path, header, v2_payload(bytes, thermal))
	check(not Archive.load_authored(bad_path).ok, "unknown schema version rejected")
	header = v2_header(16, bytes, thermal)
	header.version = 1
	write_header(bad_path, header, v2_payload(bytes, thermal))
	check(not Archive.load_authored(bad_path).ok, "a version-1 label on two-layer data is rejected")
	header = v2_header(16, bytes, thermal)
	header.grid = 1000000000
	write_header(bad_path, header, PackedByteArray([1]))
	check(not Archive.load_authored(bad_path).ok, "unbounded dimensions rejected before allocation")
	header = v2_header(16, bytes, thermal)
	var other := thermal.duplicate()
	other.encode_float(16, 999.0)
	write_header(bad_path, header, v2_payload(bytes, other))
	check(not Archive.load_authored(bad_path).ok, "checksum detects a changed temperature")
	header = v2_header(16, bytes, other)
	header.layers[1].sha256 = Archive._hash(thermal)
	write_header(bad_path, header, v2_payload(bytes, other))
	check(not Archive.load_authored(bad_path).ok, "a layer checksum that disagrees with the whole is rejected")
	header = v2_header(16, bytes, thermal)
	header.layers = [header.layers[1], header.layers[0]]
	write_header(bad_path, header, v2_payload(bytes, thermal))
	check(not Archive.load_authored(bad_path).ok, "layers out of order are rejected")
	header = v2_header(16, bytes, nan_thermal)
	write_header(bad_path, header, v2_payload(bytes, nan_thermal))
	check(not Archive.load_authored(bad_path).ok, "checksum-valid non-finite temperatures are rejected before upload")
	var unsupported := bytes.duplicate()
	unsupported[unsupported.size() - 4] = 255
	header = v2_header(16, unsupported, thermal)
	write_header(bad_path, header, v2_payload(unsupported, thermal))
	var rejected := Archive.load_authored(bad_path)
	check(not rejected.ok and rejected.error.contains("unsupported material"), "checksum-valid unknown material is rejected before GPU upload")
	check(not Archive.save_authored(path, unsupported, 16, thermal).ok and Archive.load_authored(path, 16).bytes == bytes, "unsupported material cannot replace an existing valid save")
	# Files belong solely to this test's unique directory.
	for name in DirAccess.get_files_at(folder):
		DirAccess.remove_absolute(folder.path_join(name))
	DirAccess.remove_absolute(folder)
	print("World archive: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
