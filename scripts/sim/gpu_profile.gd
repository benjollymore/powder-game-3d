extends RefCounted
## Summarize complete simulation batches, preserving repeated pass names.
## Godot 4.6.3 backend source returns GPU nanoseconds; CPU stamps are microseconds.
## Metal currently supplies zero GPU timestamps: that is unavailable, not free work.

static func summarize(markers: Array, captured_frame: int) -> Dictionary:
	var result := {"available": false, "reason": "No complete simulation timestamp batch",
		"captured_frame": captured_frame, "interval_ms": {}, "occurrences": {},
		"batch_count": 0, "total_ms": null}
	var previous := -1
	var active := false
	var invalid := false
	var intervals := {}
	var occurrences := {}
	var total := 0.0
	for marker in markers:
		var name: String = marker.name
		if not name.begins_with("powder/"):
			continue
		name = name.trim_prefix("powder/")
		var stamp: int = marker.gpu_ns
		if name == "frame_begin":
			if active:
				invalid = true
			active = true
			previous = stamp
			continue
		if not active:
			continue
		var elapsed := stamp - previous
		if stamp < 0 or previous < 0 or elapsed < 0:
			invalid = true
		var milliseconds := float(elapsed) / 1e6
		intervals[name] = float(intervals.get(name, 0.0)) + milliseconds
		occurrences[name] = int(occurrences.get(name, 0)) + 1
		total += milliseconds
		previous = stamp
		if name == "frame_end":
			result.batch_count += 1
			active = false
	if active or invalid:
		result.reason = "Incomplete or non-monotonic simulation timestamp batch"
	elif result.batch_count > 0 and total <= 0.0:
		result.reason = "GPU timestamps unavailable or zero resolution (Godot 4.6.3 Metal returns zeros)"
	elif result.batch_count > 0:
		result.available = true
		result.reason = "Intervals between markers; includes queued work and synchronization"
		result.interval_ms = intervals
		result.occurrences = occurrences
		result.total_ms = total
	return result
