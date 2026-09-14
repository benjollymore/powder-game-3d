# GPU timestamp reporting

The previous profiler overwrote repeated pass names and queried render-thread-owned timestamps from its main-thread caller. It could report misleading zeros on the tested Metal backend.

`await sim.profile_report()` now queues the query on the render thread and returns a structured report. Complete simulation batches retain the captured frame index; repeated pass intervals accumulate with their occurrence counts. Unrelated engine markers and gaps between batches are excluded. Missing, incomplete, backwards, or zero-resolution data is unavailable, with no per-pass millisecond values.

This reports intervals between submitted markers, including synchronization and other queued work within those intervals. It does not isolate kernel execution. Derived preparation flushed outside a simulation batch is outside this report; use whole-frame measurements for the opt-in deferred mode.

## Backend evidence

The pinned [Godot 4.6.3 Metal implementation](https://github.com/godotengine/godot/blob/4.6.3-stable/drivers/metal/rendering_device_driver_metal.mm#L2063) zeros timestamp results and does not implement timestamp writes. The visible-device probe confirms a complete captured batch with unavailable GPU times. This is an engine limitation, not evidence that a pass takes zero time.

The [RenderingDevice implementation](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/rendering/rendering_device.cpp#L6727) requires its timestamp reads on the render thread. For a supported backend, the pinned [Vulkan conversion](https://github.com/godotengine/godot/blob/4.6.3-stable/drivers/vulkan/rendering_device_driver_vulkan.cpp#L5352) returns nanoseconds. The report converts those to milliseconds; it does not rely on the documentation's conflicting microseconds wording. No Vulkan timing calibration was performed here.

## Checks

Seven CPU checks cover repeated passes, multiple batches, conversion units, unsupported zeros, backward time, incomplete batches, and unrelated markers. [Raw output](profile-evidence/gpu-profile.log). The broader nine-suite CPU run passes **110 checks**. [Manifest](profile-evidence/cpu-results.json).

The [visible device probe](profile-evidence/timestamp-device.log) passes and reports `available=false` on Metal. The legacy benchmark caller now awaits the report and measures actual rendered frames with a watchdog; a 30-frame smoke run drew 30 frames and reported unavailable timestamps. [Smoke output](profile-evidence/benchmark-smoke.log). Its short wall-time result is not a new performance baseline. Explicit scene teardown drains pending work before exit; an earlier immediate-exit trial printed a generic ObjectDB leak warning, while the final teardown run was clean.

The coordinator also reran the integrated leaf record test (**203 checks**) and the complete input workflow plus archive/action guards (**24 + 16 + 13 checks**). [Leaf output](profile-evidence/leaf128.log), [workflow manifest](workflow-integrated/gpu-results-1cb70fff.json). The manifest filename for a focused run is derived from the selected case names; see the directory if reproducing with a different selection.

```sh
godot --headless --path . -s res://tests/milestone/gpu_profile.gd
godot --path . --always-on-top --disable-vsync -s res://tools/milestone/inspect_gpu_timestamps.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tools/bench.gd -- 30 ticks=2 profile=1 grid=128
```
