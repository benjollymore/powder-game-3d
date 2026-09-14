# Repeated editor sessions

The first two-minute integrated 256³ session completed **99 full cycles and nine asynchronous Save/Open round trips**, with **802 checks and no failures**. Every cycle preserved exact packed authored bytes through Undo/Redo and Run/Return. Renderer-reported video memory stayed at 401,063,936 bytes. This is a repeated-interaction result on a small constructed scene, not a dense-world or multi-hour stability claim.

The tested product revision was `e47e4a9`, plus the new [session harness](../../tools/milestone/editor_session_soak.gd). It includes pending authored paint, capacity fallback and native-resolution picture defaults. It precedes unsaved-document protection and the ordinary thin-liquid candidate; later results must identify those changes separately.

## Workload and measurement

Godot 4.6.3 / Metal 4 / Apple M5 Pro; one visible 1600×900 window, native 1.0 scale, bilinear mode, FXAA, VSync on. Both editor and TimeController process loops remain enabled. The harness warps the OS cursor, sends parsed engine mouse events, and restores cursor/input state on completion. It does not validate physical trackpad gestures or the native file chooser.

Each cycle paints an authored Wall stroke into the default container scene, checks exact Undo and Redo, enters Test, emits Sand for approximately 0.6 seconds, pauses, advances exactly one step, returns to Build, and undoes the authored stroke. Every tenth cycle saves the baseline, paints a temporary edit, opens the saved archive through the real threaded archive API, and checks exact baseline bytes and cleared history. All files are generated fixture data.

Full-state readbacks and archive I/O are outside the sampled active frame intervals. They still contribute to session wall time and memory. Frame samples come from `frame_post_draw`; tick counts describe authoritative submissions, with ordered readbacks verifying their resulting state. Active time totals about 60 seconds within the 120.8-second session. The harness stores per-cycle mean and p95, not every raw frame interval, so the report does **not** invent a global p95 from those summaries.

| First 256³ run | Result |
| --- | --- |
| Total elapsed / cycles / archive round trips | 120.800 s / 99 / 9 |
| Sampled active frames / duration | 7,170 / 59.939 s |
| Weighted active-frame mean | 8.360 ms |
| Median of per-cycle p95 values | 8.530 ms |
| Range of per-cycle p95 values | 8.466–8.898 ms |
| Requested active simulation rate | 119.772 ticks/s, target 120 |
| Renderer video memory | 401,063,936 bytes throughout |
| RSS before cycles / cycle 10 / final | 654,320 / 855,344 / 855,712 KiB |
| RSS range from cycle 10 onward | 789,840–855,712 KiB |
| Retained history after ordinary cycles | One Redo, 32,768 bytes; zero after Open |

RSS rises during warm-up, then fluctuates as full snapshot buffers are retained/released; the final reading is 368 KiB above cycle 10. The harness itself retains full 64 MiB voxel snapshots and accumulated per-cycle result dictionaries, so these figures are not the uninstrumented editor's memory requirement. The flat renderer counter and bounded observed RSS are encouraging within this run; they do not prove absence of slower leaks or driver allocations outside Godot's counter.

Evidence: [complete log](session-evidence/256/gpu.log), [per-cycle data and actual viewport settings](session-evidence/256/result.json), [computed summary](session-evidence/256/summary.json), [final Build capture](session-evidence/256/final-build.png). Earlier smoke runs at 128³ and 256³ passed five and 13 cycles respectively; they were harness development checks, not additional independent long-session measurements.

```sh
godot --path . --always-on-top --resolution 1600x900 \
  -s res://tools/milestone/editor_session_soak.gd -- \
  grid=256 seconds=120 output_dir=/tmp/editor-session-256
```

Run with the shared GPU lease and no competing visible GPU process. The script has a duration-plus-90-second watchdog and stops after a failed cycle. Periodic Save/Open exercises programmatic path selection; opening a native chooser is deliberately outside this harness.
