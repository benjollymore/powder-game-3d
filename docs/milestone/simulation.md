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

## Authored reset and presentation time

Whole-world upload, Clear, and preset loading now share `_rt_reset_world_history()`. It clears all seven air textures, density/foam at every mip, sun history, FX pool, drawn FX instances, stale spawn records, sprite counters/buffers, and presentation clock before reconstructing the authored geometry. Regional edits do not invoke this reset. Returning to Build therefore starts from the authored world without residual heat, pressure, foam, or airborne decorative particles; it is not a full-runtime rewind.

Geometry-only `_rt_occupancy_update()` keeps its no-argument interface for editor transactions. A separate elapsed-simulation-time value is nonzero only during tick presentation. Foam decay now uses a **0.16 simulated-second half-life**, replacing `0.93` per arbitrary rebuild. A paused refresh neither decays foam nor injects a new foam source. Cosmetic spawn requests are disabled for zero-time refresh, while required airborne-grain, leaf, and droplet layers still regenerate. FX pool integration already consumes elapsed ticks; its seed clock now uses the absolute simulated tick, and paused refresh preserves live FX instances and their count.

These are intentional visual-time changes. Foam source sampling and cosmetic FX integration remain a per-submission presentation approximation, so different tick batches are not promised pixel-identical effects. GPU sprite/FX allocation also uses parallel atomics. The authoritative voxel/air invariance contract remains exact. RGB field reconstruction and physical sprite exclusions are unchanged.

The new `presentation_reset.gd` checks eight repeated zero-time field refreshes for exact bytes, the foam half-life, unchanged authoritative state, required physical sprites while paused, existing FX preservation without new cosmetic spawn requests, and complete history reset through all three whole-world replacement paths. All **31 checks passed at 128³**; [presentation128-step2.log](evidence-simulation/presentation128-step2.log). These include real populated foam/FX fixtures, rather than only comparing empty buffers.

The previously unused voxel push-constant slot is now explicitly reserved/zero instead of carrying the batch-local loop index, preventing a future rule from accidentally depending on submission grouping.

After presentation/reset changes, all **74 existing GPU128 checks** and **30 cadence checks** passed again: [gpu128-step2.log](evidence-simulation/gpu128-step2.log), [cadence128-step2.log](evidence-simulation/cadence128-step2.log).

## Fixed-tick live sources

A held live source is an ordered simulator command, rather than a list of duplicate render-frame stamps. `set_live_emitter(center, radius, element, mode, rate, seed, surface={})` enables or updates it; `clear_live_emitter()` stops it. The first enable stamps before the next simulation tick. Repeated position/rate metadata updates preserve fractional phase; a new seed denotes a fresh source session. Each later stamp executes between individual physical ticks, before air/voxel transport, so ONLY_AIR sees the same intervening particle motion independently of submission grouping.

Rate is stamps per **simulated second**. Pausing emits nothing, wall-clock stalls create no separate emission backlog, and work is bounded to one source stamp per simulation tick even for extreme requested rates. If simulation cannot keep up with wall time, both the world and source slow together. Source-attempt counts are not accepted material mass: cells blocked by ONLY_AIR may reject a stamp. The regression compares complete voxel state and actual sand count/water amount, not just scheduler counters.

The optional surface dictionary is deeply copied, then resolved by the editing backend on the GPU immediately before a due source stamp. `_rt_prepare_surface_emitter()` prepares lazy resources outside a compute list; `_rt_surface_emitter_stamp(cl, surface, radius, element, mode, seed)` adds pick/write barriers inside the tick list. If surface support is unavailable, the source skips the stamp rather than falling back to stale center coordinates. Whole-world restore disables any active source.

`tests/milestone/live_emitter.gd` passed **34 checks at 128³**. Moving source metadata and a 24→36 stamps/s rate change at fixed tick boundaries produced **1,161 sand cells** or **366,600 water amount units** after 96 ticks, byte-identical across `[1]`, `[3]`, and `[7,2,5,1,9]` batch schedules; all internal air textures also matched. Each replay scheduled 25 source attempts. Lifecycle checks cover paused enable, first-tick injection, metadata updates preserving phase, release, a one-stamp-per-tick work bound, and disabling on world replacement. [emitter128-step3.log](evidence-simulation/emitter128-step3.log).

```sh
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/milestone/live_emitter.gd -- grid=128
```

The source test covers cell/workplane targets. The editor's atomic surface hook requires its separate integration regression; this simulator-only branch does not claim to validate the missing backend. New cadence/reset/source GPU harnesses have a 120-second watchdog so an unexpected script error cannot leave a test window running indefinitely.

After source integration, **30 cadence checks** and **31 presentation/reset checks** passed again: [cadence128-step3.log](evidence-simulation/cadence128-step3.log), [presentation128-step3.log](evidence-simulation/presentation128-step3.log).
