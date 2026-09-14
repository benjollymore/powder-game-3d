# Editing fundamentals checkpoint 1

Ordinary build strokes now capture exact packed bytes only from first-touched 8³ GPU tiles. A transaction copies each tile before its first mutation, then edits immediately; asynchronous readback completes the undo entry after the gesture closes. Repeated and overlapping brush/region commands retain the same original before-image. Undo restores these regions without resetting unrelated simulation fields. There is no full-volume CPU snapshot at the beginning of a stroke.

The measured tiny stroke crossing two tiles transfers **4096 bytes** at both 128³ and 256³. The corresponding complete voxel volumes are 8,388,608 and 67,108,864 bytes. This is a concrete transfer reduction, not a framerate claim. Root integration will measure visible painting latency and frame distributions. Large region commands still enumerate and copy their touched tiles; GPU storage and derived renderer updates remain dense.

Transactions have a 16 MiB before-image cap and build history retains at most 128 MiB of voxel data, excluding dictionary overhead and in-flight staging copies. If a gesture exceeds its cap, the accepted prefix remains undoable and the editor says the remaining paint was skipped. An oversized region is rejected before that region changes any material. Failed/truncated readback never becomes a valid undo entry. The editor clears its history and explains the failure rather than advertising unavailable undo.

World resets advance `edit_epoch`; stale transaction commands submitted after a reset and stale undo records are rejected. `edit_revision` separately counts ordered edit submissions. Return-to-build still deliberately retains one complete authored voxel snapshot, restores it with the existing upload API and rebinds existing authored history to the new reset epoch. The simulation worker owns the centralized solver/presentation reset behind upload. This is an authored reset, not arbitrary runtime rewind.

Live held painting emits 24 additional stamps per second at a stationary valid target, independently of rendered-frame count. The initial press and connected geometric motion trail retain their existing placement behavior. A resumed/stalled frame emits at most four catch-up stamps and retains no unbounded backlog. Paused additive construction does not waste repeated dispatches stamping the same unchanged cell. Navigation and invalid/hidden targets reset the emission accumulator.

Validation before the surface-picking checkpoint:

- Regional undo GPU: 12 original checks at 128³, then 17 checks at 256³ including reset-epoch rejection, 16 MiB cap behavior and exact prefix undo. All passed. Exact equality compares every packed voxel byte, including seed/amount.
- Existing integrated interaction GPU: 19 passed, including wall preservation, brush/region undo, live paint and return-to-build.
- Existing trackpad GPU: 27 passed; native gesture-routing headless checks: 10 passed.
- Held-emission CPU traces: nine passed, including 240 stamps over ten seconds at 15, 30, 60, 120 and 240 FPS, one-minute stall cap and accumulator reset.

```sh
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/regional_undo_gpu.gd -- grid=256
godot --headless --path . -s res://tests/milestone/editing_unit.gd
```

New public transaction APIs on `VoxelSim`: `begin_edit_transaction(callback) -> id`, `record_stroke(id, centers, radius, element, mode, seed)`, `record_region(id, lo, hi, element)`, `finish_edit_transaction(id)` and `restore_edit_transaction(result) -> bool`. Region upper bounds are exclusive. Completion is observable through `edit_transaction_ready` and editor `edit_completed`, with result fields `id`, `epoch`, `regions`, `bytes`, `valid`, and `error`. Completion means before-image transfer is available, not a renderer benchmark. `capturing` remains true until the active authored gesture is sealed and its history data is ready.

Still in progress: authoritative surface picking and intent/generation rejection. Existing workplane and native gesture routing remain intact. Persistence UI and matched performance measurement are coordinated separately.

# Checkpoint 2: authoritative surface targeting

The editor now offers Workplane and Material surface targeting. Workplanes remain the default and region corner selection remains plane-based. Surface picks read the actual voxel image, skipping gas by default and supporting explicit element masks. Add centers the sphere outside the hit face by radius+1 cells; erase targets the hit cell. Section bounds also constrain picking: hidden positive-side matter cannot intercept the ray, and an add target outside the retained section is rejected.

Preview queries download 64 bytes asynchronously. Their ray/gesture intent, reset epoch and authored edit revision are checked before displaying a result. Live previews may lag simulation evolution; preview coordinates are never used as mutation authority. Painting retains frozen ray/material/radius/mode metadata and resolves that command against current ordered GPU state. A new nearer surface inserted after a preview correctly redirects the actual stamp to the nearer surface.

Build surface commands currently resolve their GPU pick with a **64-byte render-thread readback** before capturing the actual affected undo tiles. This fence is an explicit performance tradeoff to retain exact bounded undo; it is not full-volume CPU picking. A two-ray, radius-zero flat-wall stroke completed its transaction in **3819 µs** in one warm 128³ run and transferred **6144 bytes**. This single measurement is not a latency percentile or a framerate claim. Flat-face endpoints interpolate a connected line; normal/depth discontinuities and misses break the segment to avoid drawing through hidden structures. The editor retains first/latest ray samples per frame, so small intervening features at very fast motion remain a limitation to evaluate.

Live surface stamps perform query and brush dispatches in the same GPU compute list with barriers and no CPU readback. `_rt_prepare_surface_emitter()` allocates resources before opening the tick list; `_rt_surface_emitter_stamp(...)` is the simulation worker's per-tick injection hook. The editor calls the companion `set_live_emitter`/`clear_live_emitter` APIs for held painting, and the earlier frame-based duplicate stamping has been removed. The CPU emitter trace from checkpoint 1 only proved scheduling counts; it did not prove equal physical emission because repeated ONLY_AIR stamps in one frame can collapse. The companion simulator checkpoint resolves that issue by inserting stamps before the corresponding authoritative ticks.

Validation: **21 surface GPU checks**, **19 existing editor GPU checks**, **27 trackpad GPU checks**, **10 headless native-gesture routing checks**, and **11 CPU checks** passed. Surface checks cover masks, liquid/gas behavior, section boundaries, additive/erase targets, zero-direction/miss handling, exact unchanged preview state, connected flat strokes, exact undo, frozen source dictionaries, new nearer surfaces and stale preview rejection. The surface harness additionally runs actual held-surface material/count equality at tick batches 1/3/7 when the companion live-emitter API is installed; this cross-worker case is pending integration validation at this checkpoint.

```sh
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/surface_pick_gpu.gd -- grid=128
```

Integration hooks: `tools_column` exposes the root editor's action container; `_invalidate_picks()` invalidates pending preview intent for explicit load/reset/navigation. The archive UI can be attached without reworking native gesture routing. The simulator owns full-world authored reset and live-emitter cadence; this checkpoint does not alter its tick loop or temporal fields.

# Checkpoint 3: paint tools and tick-owned live input

The common palette shows Sand, Water and Wall first. “More materials” exposes Oil, Wood, Plant, Fire, Steam and Smoke using the existing simulation elements, with labeled color accents and a selected state. Radius, erase, Run and undo remain primary controls. Region selection/fill, section view, container reset and the integration's Empty build action sit under optional construction tools. Collapsing those tools explicitly exits region mode; selecting a material commits the previous gesture with its frozen material/radius before changing the tool. The exact workplane remains the default, and native Mac gesture routing is unchanged.

Integration review found that checkpoint 2's pointer path still dispatched immediate live brush geometry in addition to the new tick-owned held source. The simulator API tests alone did not catch that editor-level bypass. Runtime `_sample` now changes only frozen source metadata; `_flush` requires an authored transaction and cannot mutate live state. All runtime stamps, including surface stamps, occur inside authoritative ticks. Pointer events can update where the source will paint on the next tick, but extra pointer samples between the same two ticks do not add material.

A primary release calls the companion `finish_live_emitter()` API: a click released before its first tick retains one frozen, queued stamp. A source that has already emitted simply stops. Navigation, tool changes and focus loss cancel unfinished sources instead. A path that crosses the toolbar stops its current source; reentering the scene while held starts another source. Live painting follows simulation time, so pausing simulation also pauses emission. These are runtime edits; returning to Build restores the authored world and there is no runtime undo.

The new `tests/milestone/paint_tools.gd` checks frozen metadata across material changes, selection-mode visibility, live input routing and release/focus behavior headlessly. `tests/milestone/live_paint_input_gpu.gd` exercises the production editor `_sample` and `_flush` methods against real simulation state, comparing one versus sixteen pointer samples per frame at the same tick-positioned source path, plus quick-click and surface cancellation behavior. This tests actual material, not just scheduler counts. It does not claim identical results when the source occupies different positions at authoritative tick times.

Validation on the integrated simulation cadence/reset/source/click APIs: **11 live editor GPU checks** passed. Both one and sixteen pointer samples per frame produced exactly **24 grains over 120 authoritative ticks**, with byte-identical complete voxel states. A quick click made no change while paused, added one grain at the next tick and did not continue emitting afterward. Surface input also made no pre-tick mutation. **9 headless paint-tool checks**, **10 native gesture routing checks**, **11 editing CPU checks**, **20 existing editor GPU checks** and **27 trackpad GPU checks** passed. The existing editor harness now explicitly tests the new tick-owned click policy instead of expecting an immediate paused mutation. Its screenshots default to `user://interaction-regression`; `output_dir=...` overrides that path so regression runs never overwrite historical discovery captures.

A 1280×800 screenshot was inspected: the default palette, radius, run/undo, plane, navigation, help and status fit the panel; expanded tools remain scrollable. This branch's screenshot precedes the separate presentation/theme integration. Native gesture tests use injected events; this checkpoint does not claim a new physical trackpad test. The first live harness run exposed a harness lifecycle mistake—disabling `_process` before the scene became ready was overridden by Godot initialization. Disabling it after readiness lets the harness own pointer/tick scheduling while exercising the production sample/flush methods.

```sh
godot --headless --path . -s res://tests/milestone/paint_tools.gd
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/live_paint_input_gpu.gd -- grid=128
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/discovery/interaction_gpu.gd -- grid=128 output_dir=/tmp/editor-ui-regression
```
