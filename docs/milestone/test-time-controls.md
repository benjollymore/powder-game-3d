# Inspecting a live experiment

Run still starts an experiment from the authored Build, and Space still returns to that Build. Test now exposes **Pause/Resume · P** and **Single step · N** beside the existing Run/Return controls. Single step pauses first and requests one simulation tick through the existing TimeController API. The status explicitly distinguishes `TEST · RUNNING`, `TEST · PAUSED` and `BUILD`.

Pause and Resume preserve the current experiment. They do not capture another snapshot or restore the authored world. Build hides the time controls and consumes P/N without advancing simulation. Numeric text fields keep their keyboard input. Busy authoring also blocks time actions. Painting in a paused Test retains the existing tick-owned policy: released clicks wait for a step or Resume, and continuous sources emit only when ticks run. Return clears pending steps through the existing authored-world upload/reset path.

The headless test routes keyboard events through the actual viewport and TimeController, checking Build guards, pause/resume, exactly one requested step, no follow-up ticks, busy state and numeric input focus. The GPU harness checks that Pause preserves actual voxel bytes/ticks, Single step advances one tick, Resume continues the experiment, and Return restores exact authored bytes even when a step was queued immediately before it.

```sh
godot --headless --path . -s res://tests/milestone/test_time_controls.gd
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/test_time_gpu.gd -- grid=128
```

Validation: **9 CPU controls checks**, **8 GPU phase checks**, **9 existing paint-tool checks**, and **10 native gesture routing checks** passed. The GPU test drove the real TimeController and connected production simulation while controlling frame time explicitly. The paused 1280×800 capture at `/tmp/editor-paused-1280x800.png` was inspected: Resume and Single step are accessible directly below Return, with the Test paused status visible and remaining panel content scrollable. GPU log: `/tmp/editor-test-time128.log`.
