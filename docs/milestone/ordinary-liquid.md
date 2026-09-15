# Ordinary thin-liquid coverage investigation

Status: focused correction and targeted GPU validation complete; integration review pending. This is independent of sprite-capacity overflow.

A paused radius-zero liquid paint writes a real liquid cell with amount 200 and no falling flag. The authoritative surface picker traverses those bytes, whereas the visual renderer traverses a reconstructed density field. Ordinary liquid has no droplet sprite to cover a reconstruction omission.

## Two distinct source mechanisms

`fields.glsl` remaps a cell's fill to a density chosen for a partial film resting on a full cell. Missing same-layer liquid neighbors contribute the cell's own density; the output is quantized to RGBA8. This construction does not guarantee an isosurface for unsupported small volumes.

For an isolated full cell, its center density is 1 and its trilinear field has a real 0.5 isosurface. The volume shader samples only the DDA cell boundaries. A ray parallel to Z with a noncentral X or Y coordinate sees less than 0.5 at both cell faces, although its interior maximum can exceed 0.5. Merely changing opacity cannot help because no liquid segment opens.

For amount 50 (one quarter cell), the maximum density is 85/255, below the 0.5 threshold everywhere. Finer marching cannot recover a nonexistent isosurface. An unsupported uniform horizontal sheet at amount 100 has only 0.0078125 cell of isosurface thickness after quantization, although its authored amount is half a cell. A supported film has a different neighboring field and must not be conflated with this case.

The dependency-free reference models only these exact local reconstructions. It advances no simulation time and is not a liquid solver:

```sh
python3 tools/milestone/ordinary_liquid_reference.py
```

It checks 400 noncentral full-cell rays whose interior peaks exceed the threshold while both face samples remain below it. Exact density values and unsupported sheet thicknesses are in `ordinary-liquid-evidence/field-reference.json`.

## GPU reproduction design

`tests/milestone/ordinary_liquid_probe.gd` uses the archived pre-correction volume shader from commit `90251ffd`, native 320×320 resolution, no spatial AA, paused simulation, and no FX. It uploads water and oil with amounts 1, 50, 100, 150, 200 and 255, each as an isolated cell or a 5×5 sheet along X/Y, from front and oblique views. The probe retains exact authoritative voxel hashes, reads field peaks and physical sprite counters, asks the authoritative surface picker, and captures normal appearance plus integrated optical length. A final case calls the actual radius-zero paint entry point.

The negative-control assertions require ordinary isolated-cell omission; passing this historical reproduction demonstrates the defect, not a fix. The normal render capture and optical-length diagnostics serve different purposes: an optical segment proves representation, while appearance still needs visual inspection.

## Reproduced on Metal

The pinned baseline completed **316 checks, zero failures**. Every isolated water/oil view had zero integrated optical pixels (24 views across six amounts and two angles); raw-cell picking succeeded in every fixture. The actual paused radius-zero paint also had zero optical pixels. Authoritative arrays were unchanged, and ordinary-liquid droplet count, eligibility, and overflow flag were all zero. This is missing physical representation, not a sprite-capacity issue.

Water and oil produced identical coverage counts for these matched geometric fixtures. Representative water results:

| Amount | Isolated front / oblique | Horizontal sheet front / oblique | Vertical sheet front / oblique |
|---|---:|---:|---:|
| 1 | 0 / 0 | 0 / 0 | 0 / 0 |
| 50 | 0 / 0 | 0 / 0 | 0 / 0 |
| 100 | 0 / 0 | 0 / 107 | 0 / 107 |
| 150 | 0 / 0 | 5516 / 5028 | 5516 / 5028 |
| 200 | 0 / 0 | 35148 / 34696 | 35148 / 34696 |
| 255 | 0 / 0 | 35148 / 34696 | 35148 / 34696 |

All counts are diagnostic pixels at native 320×320, not a fidelity metric. `baseline/probe.json`, `probe.log`, and matched normal/length images preserve the evidence.

```sh
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync \
  -s res://tests/milestone/ordinary_liquid_probe.gd -- grid=128
```

The proposed rescue uses a gravity-aligned slab only when ordinary nonfalling liquid has air/gas on both opposing sides along at least one axis. It accounts for volume as width × height × depth = min(amount/200,1); compressed amount 255 keeps height 1 and optical density 1.275, rather than extending beyond the cell. No physical bytes, compute reconstruction, or sprite eligibility change. The classifier ignores visual section cuts.

A partial tilted sheet has no stored surface orientation: bottom-anchored slabs will form steps or gaps along the cell lattice. The proposal does not reconstruct a smooth tilted film and does not solve the renderer's general topology problem. Transitioning between one-cell-thick and thicker structures can switch between slab and isosurface geometry. These are explicit costs of the local rescue and require matched inspection before adoption.

## Initial corrective validation

The first candidate completed **424 matched-fixture checks** and **138 camera/section checks**, with no failures. The 72 matched views use independent ray/slab intersection sums for every authored cell. The camera/section suite covers six amounts from front, oblique, inside, all three section directions, and full removal. Pixel-center rays whose expected path is at least 0.003 cell must produce nonzero optical length; the separate absolute path tolerance is 0.035 cell. Silhouette paths below 0.001 cell are excluded explicitly.

Across both suites, 693379 independent ray probes had maximum optical-length error 0.01124831 cell. Actual paused radius-zero water paint changed from zero optical pixels to 23716.

These initial tests precede final combined-interface, unchanged-control and cost validation. The rescue explicitly excludes the falling flag; it does not establish coverage of every possible partial-liquid state. Unsupported multi-cell-thick low-fill clusters can still remain below the isosurface threshold without meeting this local thin-feature classification. That case remains a recorded limitation, not a silently widened success criterion.

## Final interface, regression, and cost checks

Final combined-production-default interface tests pass **119 checks**. They cover ordinary→overflow and overflow→ordinary adjacency, separated liquid bodies, section entries, camera-inside behavior, opaque blocking, and an ordinary proxy joining a regular bulk segment. Both regular and analytic surface entries are counted; center-ray optical lengths are checked independently. A proxy that ends already inside the regular field initializes that segment exactly at the shared endpoint rather than bisecting a nonexistent crossing and inventing an air interface.

The historical overflow-only interface suite now explicitly sets `ordinary_thin_proxy=false`. Its previous ordinary-neighbor case counted only the overflow proxy; enabling the newly visible ordinary proxy changes what that diagnostic counts. The historical suite remains isolated and passes **66 checks**. The separate combined suite tests the actual default configuration rather than leaving their interaction untested.

The fast path applies only to **amount exactly 200**, in the same already-open liquid segment, with both field endpoints at least 0.5. That full-cell interval is already represented and requires no neighbor classification. Partial, compressed, entry/exit, and material-change intervals still use the classifier. No N³ allocation, compute pass, mask packing, or authoritative write is introduced.

A compressed ordinary thin cell inside a regular segment has expected optical length 2.775 cells across the fixture; the measured result is **2.775487**. The deliberately wrong `>=200` fast path measures **2.495842** and fails exactly that optical gate. Its expected failure is retained in `compressed-negative/`; the production suite has zero failures.

An initial version of that fixture started outside the regular surface and measured 3.196411 versus its overly exact 3.275 box expectation. It mixed the pre-existing regular isosurface/bisection error with the new compressed interval, and its reflection-off expectation also incorrectly ignored a regular surface. The regular marcher still uses four bisection steps and can move an already-above-threshold entry inward; general regular-surface accuracy is **not fixed here**. Failed log/JSON are retained as `interfaces/initial-compressed-fixture.*`. The final compressed test starts inside the regular segment, so its expectation isolates interior mass-density accounting without changing tolerances or production behavior to accommodate the failure.

Unchanged controls pass **28 checks**: full bulk, supported partial film, and a two-cell-thick full sheet have byte-identical before/after images. A thicker unsupported low-fill fixture also remains unchanged—and omitted—recording the classifier's limit. The final 256 reservoir before/after images and full voxel arrays are byte-identical.

Existing regressions pass: liquid section depth **61**, liquid exit **102**, overflow interface **66**, and overflow geometry **145**. Their new evidence is under `regressions/`, leaving historical captures intact. There are **1,083 positive GPU checks** across the matched probe, ordinary geometry/interfaces/controls, and these four existing suites; the pinned historical omission reproduction adds 316 checks, and the compressed negative control intentionally fails one of 119 checks.

### Bounded rendering-cost measurement

Frozen 256-grid reservoir, **1,048,576 full ordinary water cells**, native 900×700, FXAA, VSync off, always-on-top, alternating original/candidate three times, 30 warm-up frames plus 120 measured frame-post-draw intervals per sample. These are wall intervals, not GPU device timestamps or active simulation throughput.

| Variant | Median frame interval across three samples |
|---|---:|
| Original shader | 2.289–2.305 ms |
| Initial unoptimized classifier | 3.162–3.172 ms in its earlier paired run |
| Final classifier with nominal-full fast path | 2.372–2.391 ms |

Final paired median overhead is **0.076–0.102 ms**, approximately **3–4%** in this fixture. The first version added 0.859–0.875 ms and was rejected for integration. Its separate original/candidate measurements and shader are retained in `cost-unoptimized/`. Frame p95 remains roughly 8 ms with substantial presentation scheduling noise; means vary enough that this experiment does not justify an FPS claim. Sparse/partial-heavy scenes and live editing need broader integrated performance checks. Window occlusion would invalidate these timings.

### Useful visual comparisons

- Missing radius-zero full water: [before](ordinary-liquid-evidence/baseline/3-200-single-oblique-normal.png), [after](ordinary-liquid-evidence/fixed/3-200-single-oblique-normal.png).
- Quarter-cell water: [before](ordinary-liquid-evidence/baseline/3-50-single-oblique-normal.png), [after](ordinary-liquid-evidence/fixed/3-50-single-oblique-normal.png).
- Full thin horizontal sheet: [before](ordinary-liquid-evidence/baseline/3-200-sheet-y-oblique-normal.png), [after](ordinary-liquid-evidence/fixed/3-200-sheet-y-oblique-normal.png).
- Topology transition remains obvious: [one-cell-thick slab](ordinary-liquid-evidence/controls/thin-full-on.png), [two-cell-thick isosurface](ordinary-liquid-evidence/controls/thick-full-on.png).
- [Tilted partial staircase](ordinary-liquid-evidence/controls/tilted-partial-on.png) exposes the gravity-aligned slab shape; this is not a smooth tilted film.

The correction restores readable cell-scale material presence and removes the thin-sheet edge spikes in this fixture. It is a coarse coverage repair, not final fluid fidelity. Surface picking still follows authoritative voxel cells rather than exact partial-slab geometry, so a partial cell's unfilled upper space can remain pickable. Falling sprites retain their prior eligibility and geometry. No claim is made that all low-fill or compressed bulk configurations are now represented conservatively.

### Reproduction commands

All commands run from this worktree with `/opt/homebrew/bin/godot`, under an exclusive visible GPU lease. The original probe defaults to the pinned negative control; add `candidate=1` for the correction. Output directories are overridable where specified.

```sh
python3 tools/milestone/ordinary_liquid_reference.py
/opt/homebrew/bin/godot --headless --path . --check-only -s res://tests/milestone/ordinary_liquid_probe.gd
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/ordinary_liquid_probe.gd -- grid=128 candidate=1
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/ordinary_liquid_geometry_gpu.gd -- grid=128
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/ordinary_liquid_interface_gpu.gd -- grid=128
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/ordinary_liquid_controls_gpu.gd -- grid=128
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/ordinary_liquid_cost.gd -- grid=256
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/ordinary_liquid_interface_gpu.gd -- grid=128 bad_compressed_fast_path=1 output_dir=res://docs/milestone/ordinary-liquid-evidence/compressed-negative
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_liquid_section_gpu.gd -- grid=128 output_dir=res://docs/milestone/ordinary-liquid-evidence/regressions/depth
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_proxy_interface_gpu.gd -- grid=128 output_dir=res://docs/milestone/ordinary-liquid-evidence/regressions/overflow-interface
/opt/homebrew/bin/godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_proxy_geometry_gpu.gd -- grid=128 output_dir=res://docs/milestone/ordinary-liquid-evidence/regressions/overflow-geometry
```

The liquid-exit rerun used an exact temporary copy of `render_liquid_edges_gpu.gd` with only its fixed `OUT` changed from `liquid-edge-evidence` to `ordinary-liquid-evidence/regressions/exit`; it was executed with the same visible flags and `grid=128`, then removed. Headless parser checks also passed for the other four new Godot scripts. No compute import was needed because this unit changes only the spatial shader and diagnostics.
