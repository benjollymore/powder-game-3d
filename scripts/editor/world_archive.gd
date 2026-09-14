class_name WorldArchive
extends RefCounted
## Versioned authored voxel archives. Runtime solver snapshots are a different
## format: this file deliberately stores only the construction to run again.
const MAGIC := "P3DA"
const VERSION := 1
const SCHEMA := "material-seed-amount-flags-rgba8-v1"
const MAX_HEADER_BYTES := 4096
const MAX_GRID := 256


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}


static func _hash(bytes: PackedByteArray) -> String:
	var digest := HashingContext.new()
	digest.start(HashingContext.HASH_SHA256)
	digest.update(bytes)
	return digest.finish().hex_encode()


static func _valid_grid(grid: int) -> bool:
	return grid >= 16 and grid <= MAX_GRID and grid % 8 == 0


static func _unsupported_material(bytes: PackedByteArray) -> int:
	var material_count := Elements.count()
	for offset in range(0, bytes.size(), 4):
		if bytes[offset] >= material_count:
			return bytes[offset]
	return -1


static func save_authored(path: String, bytes: PackedByteArray, grid: int) -> Dictionary:
	if not _valid_grid(grid) or bytes.size() != grid * grid * grid * 4:
		return _error("The authored world has an unsupported size.")
	if _unsupported_material(bytes) >= 0:
		return _error("The authored world contains an unsupported material.")
	var payload := bytes.compress(FileAccess.COMPRESSION_ZSTD)
	if payload.is_empty():
		return _error("The world could not be compressed.")
	var header := {"version": VERSION, "kind": "authored", "grid": grid,
		"cell_size_m": 0.01, "schema": SCHEMA, "codec": "zstd",
		"size": bytes.size(), "sha256": _hash(bytes)}
	var metadata := JSON.stringify(header).to_utf8_buffer()
	var temporary := path + ".partial-%s" % Time.get_ticks_usec()
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _error("Cannot write the world file: %s" % error_string(FileAccess.get_open_error()))
	file.store_buffer(MAGIC.to_ascii_buffer())
	file.store_32(metadata.size())
	file.store_buffer(metadata)
	file.store_buffer(payload)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temporary)
		return _error("Writing the world failed: %s" % error_string(write_error))
	# A same-directory rename preserves the previous save if writing fails.
	var renamed := DirAccess.rename_absolute(temporary, path)
	if renamed != OK:
		DirAccess.remove_absolute(temporary)
		return _error("Cannot replace the world file: %s" % error_string(renamed))
	return {"ok": true, "path": path, "header": header, "file_bytes": 8 + metadata.size() + payload.size()}


static func load_authored(path: String, expected_grid: int = 0) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error("Cannot open the world file: %s" % error_string(FileAccess.get_open_error()))
	var length := file.get_length()
	if length < 9 or file.get_buffer(4).get_string_from_ascii() != MAGIC:
		return _error("This is not a Powder 3D authored world.")
	var header_size := file.get_32()
	if header_size <= 0 or header_size > MAX_HEADER_BYTES or header_size > length - 8:
		return _error("The world header is incomplete or invalid.")
	var parser := JSON.new()
	if parser.parse(file.get_buffer(header_size).get_string_from_utf8()) != OK or not parser.data is Dictionary:
		return _error("The world header cannot be read.")
	var header: Dictionary = parser.data
	if header.get("version") != VERSION or header.get("kind") != "authored" or header.get("schema") != SCHEMA or header.get("codec") != "zstd":
		return _error("This world uses an unsupported format version.")
	var stored_grid: Variant = header.get("grid")
	if not (stored_grid is int or stored_grid is float):
		return _error("The world dimensions are invalid.")
	if not is_finite(float(stored_grid)) or float(stored_grid) != floor(float(stored_grid)) or float(stored_grid) < 16 or float(stored_grid) > MAX_GRID:
		return _error("The world dimensions are unsupported.")
	var grid := int(stored_grid)
	if not _valid_grid(grid) or header.get("cell_size_m") != 0.01:
		return _error("The world scale is unsupported.")
	if expected_grid != 0 and grid != expected_grid:
		return _error("This world needs a %d³ session; the current session is %d³." % [grid, expected_grid])
	var byte_count := grid * grid * grid * 4
	if header.get("size") != byte_count or not header.get("sha256") is String or header.sha256.length() != 64:
		return _error("The world data description is invalid.")
	var payload_size := length - 8 - header_size
	# Validate every allocation bound before reading or decompressing the body.
	if payload_size <= 0 or payload_size > byte_count + 1048576:
		return _error("The world data length is invalid.")
	var payload := file.get_buffer(payload_size)
	file.close()
	if payload.size() != payload_size:
		return _error("The world file is incomplete.")
	var bytes := payload.decompress(byte_count, FileAccess.COMPRESSION_ZSTD)
	if bytes.size() != byte_count or _hash(bytes) != header.sha256:
		return _error("The world data is damaged or incomplete.")
	# Compute kernels index the element table directly. A valid checksum does
	# not make an unknown material safe to upload. This scan runs in ArchiveJob
	# for editor loads; all seed/amount/flag bytes remain exact.
	var unsupported := _unsupported_material(bytes)
	if unsupported >= 0:
		return _error("This world contains an unsupported material (%d)." % unsupported)
	return {"ok": true, "bytes": bytes, "header": header}
