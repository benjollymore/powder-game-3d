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

### Quick clicks remain tick-owned

`finish_live_emitter()` distinguishes an intentional release from cancellation. If the source has not had its first tick, release captures one immutable click command with its center/ray, radius, material, write policy, and seed, then stops the continuous source. Multiple quick clicks remain distinct FIFO commands. If the source already attempted its first tick, release adds no duplicate. `clear_live_emitter()` cancels an unstarted continuous source without creating a click.

There are at most **32 pending clicks**, drained at most **four per tick**, before a newer held source. Overflow explicitly preserves the first 32 and rejects the newest with a warning. Whole-world upload, Clear, and preset reset cancel the pending queue, so a released click cannot leak into a replacement authored world. No click forces extra simulation ticks or mutates the world directly on release.

`live_click.gd` passed **19 GPU checks at 128³**: distinct sand/water clicks retain their metadata, no pre-tick mutation, no duplicate on an already-emitting release, navigation cancellation, all reset paths, explicit queue/work bounds, and matching voxel bytes across one/three/irregular tick batches. [click128.log](evidence-simulation/click128.log) contains the expected overflow warning from the deliberate 33-click limit test.

The original held-source regression also passed all **34 checks** after sharing its tick injection path with quick clicks: [emitter128-click.log](evidence-simulation/emitter128-click.log).

## Opt-in render-preparation coalescing

`sim.defer_render_preparation = true` (or user argument `defer=1`) enables coalescing; it remains **off by default**. Authoritative edits and fixed solver ticks still execute in their original order. Derived occupancy, fields, sprites, lighting, and elapsed cosmetic integration are prepared once before viewport drawing. Explicit `flush_render_preparation()` is an ordering barrier, not GPU completion. Public voxel/velocity/density/occupancy/sprite inspection readbacks flush pending preparation; asynchronous sound telemetry reads the last prepared frame without forcing an early rebuild.

Scheduling uses `RenderingServer.frame_pre_draw`, not a guessed Node process priority. In the [Godot 4.6.3 implementation](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/rendering/rendering_server_default.cpp#L406), this signal fires on the main thread immediately before viewport drawing is queued. Queuing our render-thread flush from that callback places it after ordinary edit/deferred callbacks and before the draw. Mode changes are themselves ordered render-thread commands; world replacement discards pending old-world presentation time.

Validation: **12 preparation checks** prove ordered mixed edit/tick equivalence and seven→one recorded preparations, paused next-frame publication, inspection freshness, and mode/reset boundaries. **Four visible capture checks** add a wall in the next rendered image (37,258 changed pixels), then clear it after an inspection barrier; the resulting empty image has **zero residual changed pixels**. The viewport test disables temporal scaling/AA to make image comparison deterministic; it is a freshness check, not a proposed visual style. [preparation128.log](evidence-simulation/preparation128.log), [prepare-capture128.log](evidence-simulation/prepare-capture128.log), [filled capture](evidence-simulation/prepare-filled.png), [cleared capture](evidence-simulation/prepare-cleared.png).

With `defer=1`, the existing **74 GPU128 invariants**, **31 presentation/reset checks**, and **34 held-source checks** also passed: [gpu128-deferred.log](evidence-simulation/gpu128-deferred.log), [presentation128-deferred.log](evidence-simulation/presentation128-deferred.log), [emitter128-deferred.log](evidence-simulation/emitter128-deferred.log). Cosmetic time/source sampling still has the declared per-presentation approximation; this option does not promise pixel-identical moving FX across different preparation groupings.

### Fresh controlled measurements

`tools/milestone/prepare_bench.gd` measures the **current fixed-air, fixed-source implementation**, not the earlier discovery algorithm. Visible always-on-top 1600×900 window, VSync disabled, default 0.75 scaling, fixed close camera, 30 warmup + 120 measured frames, two ticks per running frame, M5 Pro. Each case resets Demo and deterministic inputs. Two passes reverse variant order. The scheduler autoload is paused and ticks are requested manually; the soundscape remains loaded but sees the paused scheduler. A tiny final synchronous counter read includes outstanding GPU tail work in the aggregate mean; full voxel/air readbacks and hashing occur after timing stops. Each workload ends with identical voxel and air hashes in both variants (**16 paired comparisons passed** across both grid sizes).

Numbers below are drained mean milliseconds, repeat 0 / repeat 1. They are whole-frame wall time, not isolated GPU pass cost. Frame p95s and hashes are in the raw logs.

| Grid / workload | Immediate preparation | Coalesced preparation |
|---|---:|---:|
| 128³ active Demo | 5.049 / 4.877 | 4.797 / 4.934 |
| 128³ ticks plus separate frame edit | 5.281 / 5.471 | 4.929 / 5.013 |
| 128³ fixed-tick live source | 5.050 / 4.971 | 4.794 / 4.968 |
| 128³ paused four-point stroke batch | 3.129 / 3.153 | 2.983 / 3.145 |
| 256³ active Demo | 15.042 / 15.021 | 15.033 / 15.048 |
| 256³ ticks plus separate frame edit | **18.347 / 18.342** | **15.043 / 15.050** |
| 256³ fixed-tick live source | 15.070 / 15.080 | 15.068 / 15.054 |
| 256³ paused four-point stroke batch | 5.592 / 5.630 | 5.604 / 5.483 |

The separate tick-plus-edit workload falls from 300 to 150 preparations, improving its mean by **6.7–8.4% at 128³** and **about 18% at 256³**. Its 256³ frame p95 improves from 19.91/19.73 to 16.49/16.46 ms. This is an explicit synthetic ordered transaction, not a claim that the new editor's held-source path gains 18%: the fixed-tick live source already prepares once per tick batch and its control shows essentially no 256³ change. Likewise the paused stroke already batches four points into one preparation. Coalescing is useful infrastructure for multiple mutations, not a cure for dense simulation scaling.

These are short main-scene trials, not the integrated editor's input-to-photon latency, long-session thermals, or broad hardware coverage. Full-main-scene benchmark/capture teardown sometimes emits the existing `ObjectDB instances leaked at exit` warning; logs retain it. The standalone simulation regression scenes exited without that warning. [prepare-bench128.log](evidence-simulation/prepare-bench128.log), [prepare-bench256.log](evidence-simulation/prepare-bench256.log).

```sh
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/milestone/render_preparation.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/milestone/prepare_capture.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd -- grid=128 defer=1
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/milestone/prepare_bench.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/milestone/prepare_bench.gd -- grid=256
```
