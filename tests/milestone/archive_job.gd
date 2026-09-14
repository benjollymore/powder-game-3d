extends SceneTree
const Job := preload("res://scripts/editor/archive_job.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func run() -> void:
	var path := "user://archive-job-%s.p3d" % Time.get_ticks_usec()
	var bytes := PackedByteArray()
	var grid := 128
	bytes.resize(grid * grid * grid * 4)
	bytes.fill(0)
	bytes[4] = 3
	bytes[6] = 128
	var job := Job.new()
	var start := Time.get_ticks_usec()
	check(job.save_authored(path, bytes, grid) == OK, "background save starts")
	check(job.load_authored(path, grid) == ERR_BUSY, "an active job cannot be overwritten")
	var frames := 0
	while not job.is_ready():
		await process_frame
		frames += 1
	var result: Dictionary = job.take_result()
	check(result.ok, "background save completes")
	print("SAVE grid=%d elapsed_ms=%.2f process_frames=%d compressed_bytes=%d" % [grid, (Time.get_ticks_usec() - start) / 1000.0, frames, result.get("file_bytes", 0)])
	check(job.load_authored(path, grid) == OK, "completed job can be reused for load")
	while not job.is_ready():
		await process_frame
	result = job.take_result()
	check(result.ok and result.bytes == bytes, "background load returns exact authored data")
	DirAccess.remove_absolute(path)
	print("Archive job: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
