extends SceneTree
const Profile := preload("res://scripts/sim/gpu_profile.gd")
var checks := 0
var failures := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])

func marker(name: String, gpu_ns: int) -> Dictionary:
	return {"name": "powder/" + name, "gpu_ns": gpu_ns}

func _initialize() -> void:
	var repeated := [marker("frame_begin", 1000000), marker("air_tick", 3000000),
		marker("sim_tick", 4000000), marker("air_tick", 7000000),
		marker("sim_tick", 9000000), marker("frame_end", 10000000)]
	var report: Dictionary = Profile.summarize(repeated, 42)
	check(report.available and report.captured_frame == 42 and report.batch_count == 1,
		"complete batch retains its captured frame identity")
	check(report.interval_ms.air_tick == 5.0 and report.interval_ms.sim_tick == 3.0
		and report.occurrences.air_tick == 2 and report.total_ms == 9.0,
		"repeated passes accumulate exact nanoseconds-to-milliseconds rather than overwrite")
	var multiple := repeated.duplicate()
	multiple.append_array([marker("frame_begin", 20000000), marker("air_tick", 24000000),
		marker("frame_end", 25000000)])
	report = Profile.summarize(multiple, 43)
	check(report.available and report.batch_count == 2 and report.total_ms == 14.0
		and report.occurrences.air_tick == 3, "separate batch idle gaps are excluded")
	var zeros := [marker("frame_begin", 0), marker("air_tick", 0), marker("frame_end", 0)]
	report = Profile.summarize(zeros, 44)
	check(not report.available and report.interval_ms.is_empty() and report.total_ms == null,
		"unsupported zero timestamps do not publish zero-cost pass measurements")
	report = Profile.summarize([marker("frame_begin", 100), marker("frame_end", 50)], 45)
	check(not report.available and report.interval_ms.is_empty(), "backward GPU time is rejected")
	report = Profile.summarize([marker("frame_begin", 100), marker("air_tick", 200)], 46)
	check(not report.available, "incomplete batches cannot become a partial performance report")
	var unrelated := [{"name": "engine/opaque", "gpu_ns": 100}, marker("occupancy", 200)]
	report = Profile.summarize(unrelated, 47)
	check(not report.available, "engine and out-of-batch markers do not masquerade as simulation cost")
	print("GPU profile CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
