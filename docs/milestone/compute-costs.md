# Dense compute costs and isolated indirect experiment

The source inventory describes the milestone foundation. **The indirect implementation is not integrated into milestone/fundamentals.** It is preserved at commit `eb45856e569a4e0b32db845761a572fd5774ac1c` on `milestone/simulation`. Reproduction commands below require that experiment checkout.

This is a source inventory and a bounded profiling plan, not measured per-pass GPU attribution. The current solver now advances air at a fixed cadence every simulation tick; old batched-air timings do not establish its present costs.

| Work | Frequency | Current scope | Safe next measurement |
| --- | --- | --- | --- |
| Air downsample | Every tick | Visits all N³ voxels, summarizes 4³ per air cell | Fixed-tick whole-frame baseline; do not lower air cadence as a performance-only change |
| Air advection, divergence, pressure, projection | Every tick | 24 coarse-grid dispatches total including downsample, with 20 Jacobi iterations; each air grid has (N/4)³ cells | Diagnose pass time using validated GPU timestamps, or capture with Metal tooling; pressure iteration reductions require numerical acceptance tests |
| Margolus material step | Every tick | One thread per 2³ block, reads/writes that block; dispatch includes padded boundary groups | A future active-block test must preserve absolute partition offsets, decay, neighboring activation, and all authoritative fields |
| Hydrostatic columns and horizontal relaxation | Every tick | Two sets of N² whole-length lines, alternating horizontal axis | Cannot assume local dirty chunks: liquid redistribution and pressure depend on connected runs |
| Occupancy | Every presentation rebuild | Scans each 8³ brick; can stop once both solid and fluid categories are found | Dirty occupancy is a bounded future candidate for paused regional editing |
| Physical sprite emission | Every presentation rebuild | Full-grid dispatch, skips empty bricks, appends compact records | Indirect draw prototype below; preserve exact source data and counters |
| Fields and mip chain | Every presentation rebuild | Full-grid neighborhood reconstruction plus four smaller mip levels | Dirty editing requires the reconstruction halo and all affected mip ancestors; temporal foam cannot age per dirty refresh |
| Sun field | Every presentation rebuild | Half-resolution directional slab sweep | A local edit can affect a long shadow downstream; dirty voxel AABB alone is insufficient |
| Sprite rendering | Every visible frame | Direct path submits all configured slots, including zero-size tails | Compare paused empty/sparse/dense direct vs GPU-counted indirect |
| Cosmetic FX | When presentation time advances | Scans 32768 pool slots, writes 2 MiB instance buffer | Leave separate: live slots have holes, so the alive count cannot directly become a compact draw count |

At 128³ the authoritative packed grid is 8 MiB; at 256³ it is 64 MiB. A full-grid visit therefore covers eight times as many cells after doubling resolution. These are logical operation sizes, not DRAM bandwidth estimates: caches, early-outs, neighborhood reuse and driver scheduling matter. Empty world occupancy/downsample still inspect the grid. Paused rendering avoids solver work but continues visible draw submissions.

## Physical sprite buffer experiment

Physical instance capacities are 131072 grains, 262144 leaves and 65536 droplets. At 64 bytes per slot these reserve **28 MiB**, which the direct path clears on every presentation rebuild. FX reserves another 2 MiB of instances and 1.5 MiB of persistent pool state; it is not compact. These buffers are not all unused: their unused *tails* and direct draw capacity are the avoidable work investigated here.

The opt-in `indirect=1` prototype keeps emission unchanged and uses a one-thread finalizer per physical layer to publish `min(append_count, capacity)` to its draw command. It skips physical tail clears during normal rebuilds. Full authored resets still clear all display history. Physical state, foam/FX timing, volumetric fields, ray traversal, and material shaders are unaffected. Three command buffers add 60 bytes of logical storage; the driver may allocate more internally.

In Godot 4.6.3, `MultiMesh` lacks an indirect property while the RenderingServer allocation supports it. Initialization sets the resource's logical capacity, replaces the server allocation through zero capacity to bypass its equal-layout early return, then assigns the quad. Its command has five uints; only the second is the live instance count. The Forward+ path issues an indirect draw. See [MultiMesh resource](https://github.com/godotengine/godot/blob/4.6.3-stable/scene/resources/multimesh.cpp#L231), [MeshStorage allocation/command creation](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp#L1543), and [Forward+ draw](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/rendering/renderer_rd/forward_clustered/render_forward_clustered.cpp#L601).

**Known engine ownership issue:** the pinned engine's MultiMesh free path reallocates to zero; allocation replaces `command_buffer` with an empty RID without freeing the old buffer. Actual exit diagnostics report three leaked StorageBuffer RIDs per indirect scene, matching its three 20-byte commands. No version-specific manual-free workaround is included. The default direct path remains unchanged. The coordinator kept the entire indirect implementation isolated because this ownership defect is unresolved and the measured gain is modest. [Godot free path](https://github.com/godotengine/godot/blob/4.6.3-stable/servers/rendering/renderer_rd/storage_rd/mesh_storage.cpp#L1533).

## Profiling boundaries

The original `profile_report()` overwrites repeated timestamp names in a dictionary and reads render-thread-owned data from its main-thread caller, so its output is not sound per-pass attribution. More decisively, [Godot 4.6.3 Metal timestamp implementation](https://github.com/godotengine/godot/blob/4.6.3-stable/drivers/metal/rendering_device_driver_metal.mm#L2063) clears all query results to zero and implements timestamp writes as no-ops. Zero here means unavailable. A CPU submission timer is not GPU completion. Native Metal capture or a supported timestamp backend is needed for per-pass attribution. The new comparison therefore uses visible whole-frame wall time and a small final synchronous counter read to include queued GPU tail work. State hashes and full readbacks occur outside timing.

The benchmark runs the existing main scene in the isolated simulation worktree, not the newer integrated paint editor UI. Its paired variants share the same shaders and camera. The A/B workload separates paused draw cost from forced zero-time rebuild cost for the same physical fixture. Empty and sparse scenes expose unused-capacity overhead. A dense 131072-leaf fixture tests a substantial live prefix below the 262144 leaf cap, avoiding capacity-dependent append selection. A fixed live source with two authoritative ticks per frame tests whether the improvement survives real simulation work. Repeat order reverses to limit startup/order bias. This does not isolate exact transfer-vs-vertex milliseconds; it tests a concrete combined optimization while keeping physics identical.

## Correctness evidence

On Godot 4.6.3, Metal 4.0 / Forward+, Apple M5 Pro:

- **25 GPU checks pass**: populated grain/leaf/droplet records; exact sorted direct/indirect record equality; command index count/offset preservation; regional erase publishes zero draws while old tail bytes remain; full reset clears displayed history; tiny-capacity overflow clamps safely and produces real records; fire plus a held source preserves exact voxel bytes and all seven air textures. [indirect128.log](evidence-simulation/indirect128.log).
- **Five visible capture checks pass** at 640×480: both paths visibly draw the physical layers (2568 affected pixels), both erase without residual pixels, and the direct/indirect captures have exact image bytes (PNG SHA-256 `11f2dd9250cc9507446c5ff2da1297238981eed39b2398bc6e0b963133d707d6`). [capture log](evidence-simulation/indirect-capture128.log), [direct](evidence-simulation/indirect-false.png), [indirect](evidence-simulation/indirect-true.png).
- The existing **74 GPU128 invariant checks pass in both default and indirect modes**. Default teardown is clean; the indirect run reports the known three command-buffer leaks. [Default log](evidence-simulation/gpu128-indirect-default.log), [indirect log](evidence-simulation/gpu128-indirect-enabled.log).
- **37 CPU checks pass**, and fresh shader import/script parsing pass. The indirect tests retain the engine leak warnings described above; these are not clean teardown runs. [CPU log](evidence-simulation/unit-indirect.log).

Reproduction (run GPU commands serially in a visible unobscured window):

```sh
godot --headless --path . --import
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/milestone/indirect_sprites.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/milestone/indirect_capture.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/milestone/indirect_bench.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/milestone/indirect_bench.gd -- grid=256
```

The paired test/benchmark scripts select allocation per scene themselves; do not pass `indirect=1` to those comparisons, because that argument intentionally forces every physical layer into indirect mode. To try the opt-in path in an ordinary scene, pass `-- indirect=1` instead. Runtime reallocation, changing instance capacity, and CPU instance setters after GPU ownership are outside this prototype's contract.

## Measured A/B result

Both grids used a visible 1600×900 window, VSync off, the default 0.75 render scale, 30 warmup frames and 120 measured frames per case. Two repeats reverse allocation order. **All 24 paired full-voxel/all-seven-air hash comparisons passed**. Tables show drained mean milliseconds, repeat 0 / repeat 1; raw logs retain frame p95 and exact state hashes: [128³](evidence-simulation/indirect-bench128.log), [256³](evidence-simulation/indirect-bench256.log).

| Grid | Workload | Direct ms | Indirect ms |
| --- | --- | --- | --- |
| 128 | Empty, paused | 2.940 / 2.275 | 2.146 / 2.508 |
| 128 | Sparse physical, paused | 2.453 / 2.740 | 2.761 / 2.647 |
| 128 | Sparse physical, refresh | 2.673 / 2.696 | 2.496 / 2.572 |
| 128 | Dense leaves, paused | 2.704 / 4.389 | 3.975 / 2.650 |
| 128 | Dense leaves, refresh | 3.089 / 4.700 | 4.339 / 2.708 |
| 128 | Running source, two ticks | 4.862 / 4.751 | 4.358 / 4.499 |
| 256 | Empty, paused | 2.609 / 2.602 | 2.506 / 2.558 |
| 256 | Sparse physical, paused | 2.378 / 3.052 | 2.556 / 2.672 |
| 256 | Sparse physical, refresh | 5.209 / 5.284 | 5.000 / 4.781 |
| 256 | Dense leaves, paused | 3.094 / 5.385 | 5.109 / 2.947 |
| 256 | Dense leaves, refresh | 5.678 / 8.002 | 7.584 / 5.313 |
| 256 | Running source, two ticks | 15.033 / 15.017 | 14.620 / 14.626 |

The running 256³ source case consistently improves by **0.39–0.41 ms (2.6–2.7%)**, with frame p95 moving from 16.560/16.444 to 16.046/16.062 ms. At its final state it draws 99348 grains, 43 leaves and 4910 droplets. Sparse fixtures contain 1024/1618/1024 physical instances at 128³ or 4096/6670/4096 at 256³. Dense fixtures contain exactly 131072 leaves at both resolutions.

Short paused/dense cases show substantial variance and sometimes reverse which variant wins. Their frame p95 frequently lies near 8 ms despite a lower mean; these measurements include window/compositor/main-thread scheduling. **They do not establish a reliable general benefit for empty or dense rendering.** No per-pass GPU attribution or input-to-photon claim follows from this test. Removing a known amount of work is not itself proof of a proportional frame-time reduction.

Coordinator decision: retain indirect rendering only on its isolated, narrowly tested experiment branch. Its useful but modest running-scene improvement does not justify default activation while command-buffer teardown is unresolved. The next broader optimization should be guided by validated GPU pass timing or a Metal capture, keeping fixed tick semantics and nonlocal air/hydro dependencies explicit. The 28 MiB tail clear is real redundant work; it is not the sole or principal explanation for the 128³→256³ simulation cost increase.
