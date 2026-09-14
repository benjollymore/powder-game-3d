# Simulation fundamentals

## Fixed authoritative cadence

Air now advances once with `dt=1` immediately before each voxel tick, including when several ticks share a render-thread submission. This preserves the previous single-tick numerical algorithm: downsample current sources, advect, solve pressure, project, then update voxel rules and hydro. The old batch path advanced air once using `dt=count` against the batch's initial sources; that produced different physical worlds depending on frame grouping.

`request_ticks` remains asynchronous. Its `tick` counter records requested ticks; this change does not claim GPU completion. Regression tests explicitly wait for completed GPU readbacks.

The new `tests/milestone/batch_cadence.gd` replays Forest fire and Steam vent for 96 ticks with seeded edits at ticks 0, 17, 38, and 73. Schedules are `[1]`, `[3]`, and repeating `[7, 2, 5, 1, 9]`, truncated at edit boundaries to preserve command order in simulation time. It checks byte equality of the complete voxel texture, public velocity/heat texture, and all seven internal air textures (both velocity and pressure buffers, divergence, occupancy, sources). Readback lengths are checked separately, preventing empty or incomplete snapshots from passing equality accidentally.

At 128³, all **30 cadence checks passed**. This is stronger than the discovery's air-disabled control: default air, reactions, decay, and hydro remain enabled. Existing invariant suite: **74 checks passed at 128³**; default-grid smoke: **3 checks passed at 256³**; CPU suite: **37 checks passed**. No physics assertions or numerical thresholds were relaxed.

Reproduction, with Godot 4.6.3 and only one GPU test process at a time:

```sh
godot --headless --path . --import
godot --headless --path . --check-only -s res://tests/milestone/batch_cadence.gd
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/milestone/batch_cadence.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd -- grid=256 only=large_grid_smoke
godot --headless --path . -s res://tests/unit/run_unit.gd -- grid=128
```

A fresh worktree needs import before parser/test commands can resolve global script classes. An initial pre-import attempt failed on missing classes; it did not exercise the simulation. The successful post-import logs are retained in `evidence-simulation`.

The correctness change increases air passes for batches larger than one. Performance measurements must therefore be repeated; earlier discovery timings used the old batch-dependent algorithm. An optimization may reduce work using a fixed cadence tied to absolute ticks, but must not reintroduce a different air algorithm for each frame rate.

Evidence: [cadence128-step1.log](evidence-simulation/cadence128-step1.log), [gpu128-step1.log](evidence-simulation/gpu128-step1.log), [gpu256-step1.log](evidence-simulation/gpu256-step1.log), [unit-step1.log](evidence-simulation/unit-step1.log).
