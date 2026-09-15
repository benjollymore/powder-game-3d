class_name ArchiveJob
extends RefCounted
## Compression, hashing and disk I/O stay off the input/rendering thread.
## Poll is_ready(), then take_result(); keep the job alive while it runs.
const Archive := preload("res://scripts/editor/world_archive.gd")
var _thread := Thread.new()

## An empty `thermal` is filled with element defaults on the worker thread,
## never on the caller's frame.
func save_authored(path: String, bytes: PackedByteArray, grid: int, thermal: PackedByteArray = PackedByteArray(), ambient: float = 293.15) -> Error:
	if _thread.is_started():
		return ERR_BUSY
	return _thread.start(_save_with_defaults.bind(path, bytes, grid, thermal, ambient))

static func _save_with_defaults(path: String, bytes: PackedByteArray, grid: int, thermal: PackedByteArray, ambient: float) -> Dictionary:
	if thermal.is_empty():
		thermal = Archive.default_thermal(bytes, ambient)
	return Archive.save_authored(path, bytes, grid, thermal)

func load_authored(path: String, grid: int) -> Error:
	if _thread.is_started():
		return ERR_BUSY
	return _thread.start(Archive.load_authored.bind(path, grid))

func is_ready() -> bool:
	return _thread.is_started() and not _thread.is_alive()

func take_result() -> Dictionary:
	if not is_ready():
		return {"ok": false, "error": "The file operation has not completed."}
	return _thread.wait_to_finish()

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _thread.is_started():
		# Complete a save before its owner is destroyed; ordinary frames never wait.
		_thread.wait_to_finish()
