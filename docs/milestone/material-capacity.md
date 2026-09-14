# Physical material capacity is a visibility contract

The old renderer could omit authoritative physical cells when a sprite layer filled. This is a correctness defect, separate from decorative FX budgets. The fix switches an entire overflowing physical layer to deterministic coarse geometry. Cells, seeds, amounts, flags, and air state remain authoritative and unchanged.

## Reproduction

On Godot 4.6.3 / Apple M5 Pro / Metal, the pre-fix probe held 100 isolated physical cells and gave the selected layer 16 instance slots. Each layer emitted 16 finite instance records, leaving 84 cells without their intended representation. Airborne grains and falling quarter-full droplets had zero reconstructed density. Isolated plant cells peaked at 102/255 opaque density, below the 0.5 surface threshold, so the omitted leaves did not have a fallback surface either.

At actual default capacities, 131328 suspended grains emitted 131072 records and 65792 falling droplets emitted 65536. Both left 256 physical cells with neither sprites nor a surface. Allocation counters sometimes exceeded capacity because several threads passed the non-atomic preliminary check; the probe therefore decoded actual instance origins rather than equating a counter with represented material.

The original 56-check reproduction log, JSON and matched capped/enough-capacity images are retained in [material-capacity-evidence](material-capacity-evidence/). `material_capacity_probe.gd` records that historical failing behavior; its assertions deliberately describe the defect and will fail on the fixed implementation. The passing regression is `material_capacity_gpu.gd`.

## Perceptual comparison

Each pair below uses exactly the same 100 physical cells, camera and light; only the selected physical layer capacity changes from 100 (sprites) to 16 (whole-layer fallback). Water contains amount 50 per cell. The tighter lit captures are diagnostic fixtures, not an art-direction proposal. [Visual JSON records](material-capacity-evidence/fixed/visual.json) include full voxel SHA-256 hashes; the focused lit capture rerun passed 83 checks.

| Material | Enough capacity: original sprites | Overflow: coarse fallback |
|---|---|---|
| Sand | [Sprites](material-capacity-evidence/fixed/small-grains-enough-capacity.png) | [Cell boxes](material-capacity-evidence/fixed/small-grains-capped.png) |
| Plant | [Leaf cards](material-capacity-evidence/fixed/small-leaves-enough-capacity.png) | [Cell boxes](material-capacity-evidence/fixed/small-leaves-capped.png) |
| Water | [Droplet sprites](material-capacity-evidence/fixed/small-droplets-enough-capacity.png) | [Amount-aware boxes](material-capacity-evidence/fixed/small-droplets-capped.png) |

All matter receives geometry, but the layer-wide size/shape transition is conspicuous. Water is substantially fainter than its highlighted droplet sprites: bulk absorption/scattering alone does not provide a readable reflective interface. This is a recorded visual regression, not a claim of acceptable final paint-view treatment. Coverage correctness does not establish acceptable final visual quality. Retaining detailed shapes beyond capacity needs a separate scalable representation/budget design.

## Representation and ownership

* Counters 21–23 count **all eligible** grains, leaves and droplets, independently of capped allocation. Each eligible cell increments one of three workgroup-local counters; at most three global reductions follow per active brick. Existing instance allocation, seed and geometry code stays unchanged below or exactly at capacity.
* `fields.glsl` compares each eligible count with its capacity. If it exceeds capacity, the existing field pass zeroes **every** record in that layer, including all leaf basis components. The choice does not depend on atomic arrival order. Cosmetic FX keep their existing separate budget.
* Overflow grains and plant material receive unit opaque occupancy plus direct cell-box hits in the opaque DDA. Merely restoring density is insufficient: a single-cell density peak can be missed by cell-boundary sampling. Coarse plant geometry includes bark while that layer overflows.
* Overflow droplets remain excluded from the smooth liquid surface. The volume marcher checks the same falling/six-physical-neighbor condition as emission and intersects a centered cube contained in the source cell. Its side is `cbrt(min(amount/200,1))` cell lengths. Box volume is therefore `min(amount/200,1)` cell volumes. Optical density is `max(amount/200,1)`, accounting for compressed amounts through 255 without expanding outside the cell. Integrated optical density over box volume equals `amount/200`. Amount 0 has no mass or proxy volume. This proxy has ordinary liquid absorption/scattering, without invented reflective or refractive surfaces.
* Proxy intervals are clipped to the current DDA interval, opaque depth and visible section. Neighbor classification uses the full physical grid, so a cutaway cannot turn a connected liquid cell into spray. A neighboring ordinary liquid segment closes before the coarse proxy begins.
* The derived metadata is one 1×1×1 RGBA8 texture: R/G/B identify grain/leaf/drop overflow. Existing field channels retain their meanings; reusing the gas channel would have introduced false gas shadows. No CPU readback selects the mode. Upload, reset and later under-capacity preparation overwrite stale flags.

Resource changes: 12 previously unused counter bytes, 12 shared bytes per emission workgroup, one 4-byte logical metadata texel (driver allocation granularity is larger/unspecified), 16 additional push-constant bytes, and new bindings on the existing field pass. No extra compute dispatch, full-grid texture or authoritative per-cell bytes. Overflow alone incurs a second physical-instance clear within field reconstruction: up to 8 MiB grains, 16 MiB leaves, 4 MiB droplets at current capacities. Existing normal 28 MiB pre-emission clears remain.

## Validation

The final fixed GPU run passed **112 checks**: actual grain/drop/leaf capacities, tiny capacities, exact-capacity and below-capacity legacy byte comparisons, whole-layer suppression, deterministic repeat, recovery/reset, and exact authoritative voxel plus seven-air-texture comparisons. The existing 74-check GPU suite, 203-check leaf regression, 61-check liquid-section depth regression and 102-check liquid-exit regression also pass. [Final capacity log](material-capacity-evidence/fixed/final.log), [GPU log](material-capacity-evidence/gpu.log), [leaf log](material-capacity-evidence/leaf.log), [depth log](material-capacity-evidence/liquid-depth.log), [exit log](material-capacity-evidence/liquid-exit.log).

The independent geometry fixture passed **145 checks** with zero failures across 35 water views (212,186 independent rays) and 14 opaque views (84,314 rays). Water amounts 1, 50, 100, 200 and 255 cover front/oblique/inside cameras, all three section axes, and removed cells. It compares captured integrated optical length against CPU intersections of **both** physical boxes. Maximum error is 0.01125 cell lengths against the declared 0.035 tolerance (RGBA8/sRGB readback quantization plus existing ray-entry epsilon); opaque sand/plant silhouette coverage also agrees. [Geometry results and diagnostic images](material-capacity-evidence/geometry/regression.json).

Two invalid attempts are retained honestly: an excessively small near plane caused Godot camera-preparation errors; after correcting that, the initial CPU reference omitted the distant second physical cell that triggers overflow. Pixel (96,296) in the oblique view correctly saw that cell. The reference was expanded to include it; no pixels were masked out and the tolerance was unchanged. This was a fixture defect, not evidence of a production shader defect.

Paired timing uses the original kernels and spatial shaders retained as immutable text fixtures, with only a push-layout adapter for legacy field dispatch. A frozen mixed scene has 19,683 cells (6,561 each of grains, leaves, droplets), all below default capacity; 900×700 native resolution, spatial AA off, VSync disabled, always-on-top. Three alternating pairs measure 120 frames and 10 synchronized preparations each. Synchronization reads the **last sun-visibility output**, so preparation includes all passes and a common readback cost. These are wall times, not device timestamps.

| Metric (range of three run medians) | Original | Candidate |
|---|---:|---:|
| Preparation + final-output readback | 0.683–0.722 ms | 0.832–0.890 ms |
| Frozen frame | 1.732–2.048 ms | 1.898–1.929 ms |

The paired preparation increase is 0.141–0.207 ms in this fixture. Frame p95 values vary from 5.645–8.519 ms originally and 8.317–8.503 ms with the candidate; scheduling/presentation noise prevents a precise frame-cost conclusion. No broad speed claim follows. The paired native images differ at 2 of 630,000 pixels (maximum channel difference 23/255); screenshot bit identity is not claimed. Under-capacity record dictionaries and field bytes are independently identical to the original kernels. [Raw paired measurements and matched screenshots](material-capacity-evidence/cost/cost.json). Earlier counter-only-sink measurements are retained as provisional evidence and are not the reported final timing.

Commands, with no other GPU client obscuring the always-on-top window:

```sh
godot --headless --editor --path . --import
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_capacity_gpu.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_proxy_geometry_gpu.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_capacity_cost.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tests/gpu/run_gpu_tests.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/leaf_finite.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_liquid_section_gpu.gd -- grid=128 output_dir=res://docs/milestone/material-capacity-evidence/liquid-depth
```

The liquid-exit test was run from an exact temporary copy with only its output directory redirected into this unit's evidence folder; historical screenshots were preserved. Its production command remains `godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_liquid_edges_gpu.gd -- grid=128`.

## Limits

Whole-layer mode changes can visibly pop when the population crosses capacity. This is an explicit coarse fallback, not a proposed final material look or a momentum model. Normal sprites retain their pre-existing visual size heuristics; the amount-aware volume contract applies specifically to overflow droplets. Very small transparent or distant proxies may be subpixel, as any finite physical geometry can be. The fallback guarantees a deterministic geometric/optical representation, not an opaque visible pixel for every cell from every camera.

Voxel proxies are box-shaped and substantially less attractive than individual leaves/grains; current material lighting and dense raymarch scaling remain separate limitations. Overflow frame costs and grids larger than 128 were not measured in this unit. This work does not fix arbitrary pre-existing low-density thin-film surfaces, increase the sprite budget, or introduce a particle solver. Explicit `sprites=0` remains a profiling/debug control that bypasses physical emission; it is not a production visibility mode.
