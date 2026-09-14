# Simulation architecture discovery

This branch is a bounded experiment, not a production overhaul. The production simulation, shaders, scenes, and controls are unchanged. An additive subclass and harness test whether edit and tick work can share their derived rendering rebuild. The long-term target includes construction, rich interactions, convincing fluids, destruction/machinery, and visual realism, with fundamentals first.

## Decision

Retain Godot and GPU-resident simulation as useful foundations. Do not freeze the current four-byte cellular volume as the long-term authoritative physics model. First separate ordered edits, deterministic simulation time, and render preparation; keep dense storage as a reference implementation while evaluating active tiles. Convincing liquid momentum, thermodynamics, and moving machinery require additional state and potentially different solvers, irrespective of chunking.

The current cellular model is already a simplification of The Powder Toy, whose [Particle structure](https://raw.githubusercontent.com/The-Powder-Toy/The-Powder-Toy/master/src/simulation/Particle.h) contains position, velocity, temperature, life, and material-specific state. Three dimensions magnify the storage, visibility, and editing costs of that richer state.

## Experiment

`tools/discovery/deferred_sim.gd` subclasses the existing simulator only for this experiment. Baseline executes one deterministic radius-4 sand stamp, its normal derived rebuild, and two normal simulation ticks with their normal final rebuild. Coalesced executes the same stamp and ticks, suppressing only the stamp's intermediate derived rebuild. A paused stamp still rebuilds immediately. Empty, settled sand, and active-demo cases submit no stamps and therefore serve as unchanged controls.

This deliberately defines an edit-before-tick transaction. The normal application schedules ticks and brush actions through different callbacks; this harness does not claim to reproduce their ordering or original audit FPS exactly. It isolates the duplicated rebuild within otherwise identical ordered GPU workloads. All production voxel and air kernels are unchanged.

Each case resets the world, coarse air, foam history, sprite seed counter, and FX pool; seeded stamp positions and 300 simulation ticks are identical between variants (zero ticks for paused painting). The camera is fixed at `(0.85, 0.65, 0.85)` world widths. There are 30 warmup and 120 measured visible frames per case, followed by a GPU drain and SHA-256 readbacks of the entire voxel state and coarse velocity/heat texture. Two passes reverse variant order. Wall-clock samples await `RenderingServer.frame_post_draw`; they are whole rendered-frame observations, not isolated GPU pass timings. Window is always on top, VSync disabled, 1600×900, existing 0.75 rendering scale/default visual features. Only one GPU test application ran at a time on the audited Apple M5 Pro.

The temporal rendering caveat is substantive: `fields.glsl` decays persistent foam by 0.93 **per rebuild**, while sprite emission increments `_frame` and seeds FX requests. Skipping a rebuild changes foam history and FX randomness. Physical-state equality does not imply pixel equality. The discovery therefore establishes whether rebuild ownership is worth changing, not that its prototype is ready to ship without defining presentation time.

## Work and storage boundaries

The full rebuild includes occupancy, clearing/refilling sprite buffers, a full-resolution fields pass and four mip reductions, and a directional sun sweep. A local brush dispatch itself touches only the brush bounds. The expensive global work is a scheduling consequence, not a necessary property of a local edit.

A staged progression is safer than replacing storage and solvers simultaneously:

1. Make frame transactions explicit, with one render preparation after ordered edits and fixed simulation steps. Foam decay and FX integration must consume elapsed presentation/simulation time explicitly, independently of rebuild count. Paused painting, clear, upload, and inspection readback must flush valid derived state.
2. Retain the dense canonical grid while adding an active-tile scheduler and dirty derived fields. Use the dense path as a correctness oracle with deterministic edit traces. Measure occupancy/active ratios, CPU submission costs, and actual GPU costs before choosing tile size. Empty and static scenes are especially valuable controls.
3. Only introduce sparse resident storage if target extent, occupancy, and richer-state memory justify it. Active dispatch and sparse storage are separate choices: dense storage with sparse dispatch can save work without the lookup/boundary complexity of a sparse atlas.

An 8³ or 16³ tile is a candidate, not a benchmark-backed winner. Conservative wake-up rules must include adjacent changing tiles, reaction neighbors, temperature gradients, incoming material, externally edited solids, and persistent visual history. “No changes last tick” is insufficient for sleeping probabilistic reactions or material affected by air. Margolus partitions cross tile boundaries; partition ownership and halo validity must be explicit to preserve disjoint writes. Dirty fields need a halo large enough for their complete input dependency: the staged 3³ neighborhood includes liquid face-neighbor checks, making a simple one-cell halo insufficient for every path. Dirty mip regions must propagate upward.

The existing hydro solver streams **complete columns and alternating horizontal lines**, redistributing liquid amount over connected runs. Restricting it to an edited tile would change pressure communication and break pipe/U-bend behavior. Initially mark affected lines or connected liquid regions; sparse local pressure requires a new solver and boundary tests. The coarse air solver similarly performs global advection, divergence, 20 Jacobi iterations, and projection. Tile occupancy alone cannot determine where pressure changes matter. Retaining a dense coarse air grid is a reasonable first hybrid. Sun visibility propagates down entire shadow paths, so local changes invalidate downstream lighting beyond the edited brick. Global sprite compaction is another independent obstacle to cheap local refresh.

### Raw GPU volume payload

These are exact format/dimension arithmetic from `voxel_sim.gd`, **not measured driver allocation or peak application memory**. Texture alignment, Metal copies, render targets, undo history, scratch solvers, and GPU double buffering are excluded.

| Payload (MiB) | 128³ | 256³ | 512³ |
|---|---:|---:|---:|
| Existing RGBA8 voxel state | 8 | 64 | 512 |
| Existing RGBA8 fields, five mip levels | 9.14 | 73.14 | 585.13 |
| Existing half-resolution R8 sun field | 0.25 | 2 | 16 |
| Existing 8³-brick RGBA8 occupancy | 0.016 | 0.125 | 1 |
| Existing coarse air textures combined | 0.969 | 7.75 | 62 |
| **Existing volume subtotal** | **18.38** | **147.02** | **1,176.13** |
| Additional half-float temperature/cell | +4 | +32 | +256 |
| Additional RGBA16F velocity/auxiliary state/cell | +16 | +128 | +1,024 |
| Additional four-byte life/electrical/auxiliary state/cell | +8 | +64 | +512 |

Current fixed sprite buffers add about 30 MiB, FX pool 1.5 MiB, and spawn requests 0.125 MiB, independent of grid size. Richer fields in the table are illustrative allocations, not a finalized physical model. At 256³ those three illustrative new fields add 224 MiB; at 512³ they add 1,792 MiB before scratch/history. Keeping velocity only at a coarse fluid grid or in active particles changes this tradeoff substantially. The fourth existing voxel byte is already used for movement/falling flags in shaders; old comments calling it reserved are misleading.

## Shared interface proposal

Adopt interfaces before distributing implementation across agents:

- `EditCommand`: stable command ID, explicit application tick, ordered sequence number, voxel/world coordinate convention, sphere/box/region payload, write policy (`replace`, `only_air`, `erase`), deterministic seed, and affected bounds. A command returning success must describe what actually changed, enabling transaction-level undo. Edits cannot silently depend on rendered-frame cadence.
- `advance_fixed_steps(first_tick, count)`: schedules only authoritative simulation. Air, thermal, and future fluid substeps have explicit fixed tick cadence. Submission batching must not alter outcomes; dropped wall time is reported separately from simulated time. A later GPU completion/inspection marker identifies the completed tick, not merely requested ticks.
- `prepare_render(completed_state_version, changed_regions, presentation_dt)`: derives visual fields once per presentation transaction and exposes stable renderer handles. Renderers should not interpret packed authoritative bytes as the public material API. The initial adapter can expose the current textures plus schema/version metadata.
- `inspect_region` / `capture_region` / `restore_region`: bounded asynchronous readback and upload for targeting, inspectors, undo, persistence, and deterministic tests; versioned material/state schemas preserve future solver migration. Prefer GPU picking with a small delayed result over full-world CPU copies.
- `WorldState`: separate material identity/mass, thermal/electrical state, momentum/velocity fields, and dynamic-body state conceptually, even if the first backend uses one dense grid. A mechanical body needs a transform, velocity, connectivity/material properties and coupling to particles/fluid; repainting wall voxels is not rigid-body dynamics.

The rendering/interaction teams can work against these contracts while simulation evolves. Solver ownership of material transport and conservation at coupling boundaries must remain centralized; do not have multiple solvers independently move the same mass. A minimal hybrid test should include a momentum-carrying pour/obstacle plus a moving body, heat transfer, and the existing pressure/mass regressions before calling the simulation architecture settled.

## Measured results

Whole rendered-frame wall time in milliseconds; entries show repeat 0 / repeat 1. Variant order is reversed in repeat 1. The controls execute the same work in both variants, so their variation estimates short-run noise and drift rather than a speedup.

| Workload, two ticks/frame unless paused | Baseline mean ms | Coalesced mean ms | Baseline p95 ms | Coalesced p95 ms |
|---|---:|---:|---:|---:|
| Truly empty world | 15.492 / 18.524 | 14.106 / 16.931 | 20.662 / 23.862 | 15.227 / 22.669 |
| Settled sand layer | 15.075 / 18.613 | 15.827 / 16.115 | 17.471 / 21.972 | 20.593 / 20.301 |
| Active demo | 20.609 / 19.759 | 20.486 / 19.903 | 29.483 / 24.283 | 25.961 / 23.005 |
| Active demo + one stamp/frame | **26.668 / 24.957** | **21.908 / 21.008** | **35.137 / 30.275** | **27.128 / 24.451** |
| Paused demo + one stamp/frame | 10.391 / 11.952 | 8.984 / 10.559 | 16.783 / 18.564 | 12.296 / 17.208 |

Running painting improves mean frame time by **17.8% and 15.8%** in the two paired runs (averaged means 25.813 → 21.458 ms, about 38.7 → 46.6 FPS). Derived rebuilds fall from 300 to 150 over each 150-frame workload. All ten workload/repeat pairs end with identical whole-voxel and whole-air SHA-256 hashes. This supports consolidating derived work, but does not demonstrate reaching 60 FPS or scaling to larger worlds. It also does not address the cost of unchanged worlds: empty and settled cases still take substantial whole-frame time with fixed two-tick submission. This harness does not isolate that cost between dense simulation and rendering.

The experiment changes temporal presentation work alongside rebuild work, so the observed improvement is the cost of the complete omitted intermediate update, including its consequences for rendered FX. It is not an isolated density/occupancy pass measurement. The control cases and order reversal show why a single FPS observation would be inadequate. There is no cross-machine, long-session thermal, GPU-per-pass, 128³ performance, or dirty-tile performance result in this discovery.

### Confirmed tick batching defect

After resetting the Forest fire world, 60 ticks submitted as 60 batches of one and 20 batches of three produce:

| Air solver | Voxel bytes identical | Air velocity/heat bytes identical |
|---|---|---|
| Disabled | Yes | Yes |
| Enabled | **No** | **No** |

This reproduces the audit's previously unverified batch-invariance concern. The same nominal simulated duration can produce a different world depending on rendering/scheduling. The harness tests one scene and short horizon, so it proves divergence rather than quantifying perceived gameplay severity across scenes. With air disabled, this specific control also rules out mere submission grouping in the voxel/hydro kernels as the cause here.

Source explains the likely mechanism: `_rt_tick` calls `_rt_air_step(count, first_tick)` **once before all voxel ticks**; downsampling sees one initial state and advection/projection run once for a larger `dt`. Three one-tick batches resample changed sources and project pressure three times. Those are different numerical algorithms. Fix simulation cadence before optimizing dispatch batching, otherwise performance changes can silently change game rules. A fixed coarse-air cadence tied to absolute simulation ticks is possible; it need not mean every solver runs every voxel tick.

## Reproduction and validation

Run from this worktree with Godot 4.6.3, serially for GPU commands. The window must remain visible: previous audit work showed obscured macOS windows can stop GPU/render/readback progress while main-loop timing appears healthy.

```sh
godot --headless --path . --import
godot --headless --path . --check-only -s res://tools/discovery/simulation_bench.gd
godot --headless --path . -s res://tests/unit/run_unit.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/discovery/simulation_bench.gd -- grid=256
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd -- grid=256 only=large_grid_smoke
```

The benchmark returns failure if any baseline/coalesced pair changes voxel or air state. The batch-invariance diagnostic reports current divergence but deliberately does not treat the known existing defect as a coalescing failure. This is an experiment-specific harness, not a newly imposed gameplay acceptance test. Raw benchmark output includes every hash and rebuild count in [bench256.log](evidence-simulation/bench256.log). CPU checks: **37 checks, zero failures**, [unit.log](evidence-simulation/unit.log). Headless import and benchmark syntax check passed. No headless timing claims were used.

## Build/test contract for the editor direction

The user's Amulet/MCEdit and Besiege references strengthen the need to separate an **authored scene** from a **running experiment**. Starting Test should instantiate the authored material/geometry, initial fields, and mechanical bodies. Returning to Build should restore that authored scene reliably. A simulation snapshot is a different object: resuming it requires the complete authoritative runtime state and absolute tick, not just element IDs. Decide explicitly whether an edit during Test mutates the experiment only or is promoted into the authored scene.

For the current backend, deterministic reset includes voxel bytes, coarse velocity and pressure, absolute tick/RNG schedule, and any persistent solver state. Presentation reset additionally clears foam at every mip, FX pool and its rendered instance buffer, spawn/counter buffers, and sprite seed counters; loading only voxels leaves stale history. The discovery harness's final reset clears the FX render buffer as well as the pool, specifically because a paused case never runs FX integration to refresh those drawn instances. An eventual authored-world transaction should own this reset centrally rather than relying on each editor feature to remember auxiliary textures.

Introduce `WorldDescriptor` with explicit voxel size in metres, integer grid/world bounds, coordinate origin, material schema, and solver configuration. Current `world_size = GRID * 0.01` ties physical extent to grid dimension, while presets rescale their reference coordinates with GRID. An editor and a future renderer need an explicit shared coordinate contract; changing visual surface detail should not silently resize the experiment or force every physical field to increase resolution.

Existing rule regression suite: **74 checks, zero failures at 128³**, [gpu128.log](evidence-simulation/gpu128.log). Default-grid smoke: **3 checks, zero failures at 256³**, [gpu256-smoke.log](evidence-simulation/gpu256-smoke.log). These exercise the unchanged production path; the additive harness separately validates physical equivalence of the coalescing prototype. Full GPU128 coverage includes mass conservation, settled sand, hydro pressure communication, combustion, air behavior, and sprites. The narrow default-grid smoke is not equivalent to repeating that entire suite at 256³.

The discovery benchmark exits successfully but Godot emits an `ObjectDB instances leaked at exit` warning even after explicit scene cleanup. This teardown warning was not investigated further in the bounded experiment; it is recorded in the raw log. No production files changed, and this harness should remain an isolated research tool until its resource lifecycle is resolved.
