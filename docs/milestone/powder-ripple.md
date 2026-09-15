# Lattice rings on smoothed powder heaps

Status: cause established on a dependency-free CPU model of the production field and shader formulas; correction validated on Metal with matched A/B captures, a byte-identical wall control and unchanged physical bytes. This is a shading-shape correction inside `voxel_opaque.gdshader`; it does not change `fields.glsl`, hit positions, sprite layers, physical bytes or any solver state.

The [presentation report](editor-presentation.md) recorded "grid-scale sand rippling" as a remaining visible defect. Sand is the first material in the paint bar and every experiment forms heaps, so concentric rings on a cone or bands on a slope are seen constantly in the paint-and-inspect loop.

## Cause

`fields.glsl` smooths powders with a centre-heavy 3³ kernel (weights 0.52 / 0.05 / 0.0125 / 0.00375). On any planar heap slope the 0.5 isosurface follows the voxel staircase with a small per-cell bump: that geometry ripple is only 0.05–0.16 cell in height and is **not** what the eye sees. The visible rings come from two shading terms that read the field at the lattice scale:

1. **Curvature darkening.** `base *= 1 - clamp(lap * 0.5, -0.12, 0.12) * smooth * detail` used the six-tap Laplacian at one cell. On a plane, which has zero curvature, that Laplacian oscillates with the lattice and the clamp saturates on both sides, so the brightness swings by 10–31% peak-to-peak at the riser spacing. The term is scaled by `detail_strength`, so the milestone editor's 0.18 setting hides most of it while the fidelity captures at 1.0 show it fully.
2. **Shading normal.** The normal was a 25/75 blend of the one-cell gradient and the level-1 (two-cell) gradient. The one-cell share carries 4–8° of lattice-periodic swing on repose-angle slopes.

AO taps are already coarse and contribute under 0.5% ripple; they are unchanged.

`tools/milestone/powder_ripple_reference.py` models the exact texel values (with RGBA8 quantization), mip chain, trilinear sampling, isosurface probe and both shader formulas on 96³-scale planar slopes of 1.0, 0.6 and 0.35 rise per cell, sampling only the mid-slope band so wide stencils never touch the plateau or floor. Ripple is the residual after a moving average over one riser spacing.

| Slope | Term | Baseline rms / peak-to-peak | Candidate rms / peak-to-peak |
|---|---|---:|---:|
| 0.6 | curvature factor | 0.066 / 0.207 | 0.011 / 0.046 |
| 0.6 | normal angle | 1.04° / 4.42° | 0.30° / 1.25° |
| 0.35 | curvature factor | 0.094 / 0.311 | 0.014 / 0.071 |
| 0.35 | normal angle | 2.35° / 8.48° | 0.62° / 2.59° |
| 1.0 | curvature factor | 0.037 / 0.100 | 0.008 / 0.026 |

Hit height ripple is identical in both variants (geometry untouched). The mean signed angle from the nominal plane normal is 5–7° for **every** stencil, including the fine one: angles do not average like slopes on a stepped surface. That bias is a property of the reconstructed field, not of this change, and is left alone. [Reference output](powder-ripple-evidence/reference.json).

```sh
python3 tools/milestone/powder_ripple_reference.py
```

## Candidate

For smoothed materials the shading normal is now a 25/75 blend of the level-1 (e = 2) and level-2 (e = 4) gradients, guarded against sign flips exactly as before, and the curvature term uses the level-1 Laplacian scaled to per-cell² units through the new `field_laplacian_coarse` helper in `voxel_dda.gdshaderinc`. Walls (smoothing 0) still take the face normal and have a zero curvature term. The one-cell gradient is still computed for the rigid face axis and the hit position is unchanged.

The first GPU run caught something the CPU model does not cover: the vector that selects *which* cell shades a hit (`behind = floor(ps - n_model * 0.6)`) had also been switched to the smoother normal, which changed the per-cell seed jitter and therefore lit brightness on walls by up to 9/255 in 33,613 bytes while wall normals stayed identical. The shader now keeps the previous 25/75 fine/coarse blend for cell selection and uses the smoother normal only for shading, so material identity and seed jitter are unchanged for every material. No gate was changed for that; the run is retained in the log history below.

Costs accepted deliberately: a single isolated smoothed cell shades as a soft bump (its shape still comes from the level-0 isosurface), and one-cell ridges lose their per-cell curvature accent. The reconstructed field's own bias and stair-step silhouettes are not fixed here.

## Review regression: caps, embedded cameras and coarse hits

Independent review of the integrated change found that the two overrides which force a flat normal (`coarse_hit` for capacity-fallback grains, and `t_hit == 0` for section caps and a camera embedded in material) still assigned only the cell-selection normal, which shading no longer read. Inside a heap the smoothed field is uniformly 255, both coarse gradients vanish, and `-normalize(0 + 1e-6)` is the constant diagonal (−0.577, −0.577, −0.577): a sand cross-section was lit as one tilted plane and the AO taps pointed into solid interior, reversing the earlier section-normals fix. The wall-only surface harness could not see it. Both overrides now also replace `n_smooth`; the regressed shader is kept as `tests/milestone/fixtures/voxel_opaque_cap_regression.gdshader`.

`render_surface_gpu.gd` now cuts **sand** on X, Y and Z, embeds the camera in sand, and cuts a plant block, decoding the cap normal image against the axis normal, with the regression fixture run as the A side so the gate is proven to detect the defect. **99 checks, zero failures** ([metrics](powder-ripple-evidence/regressions/cap-normals/surface-metrics.json), [log](powder-ripple-evidence/regressions/cap-normals/run.log), captures alongside):

| Case | Regressed fixture wrong normals / max error | Fixed wrong normals / max error |
|---|---:|---:|
| Sand section X, Y, Z (9,216 samples each) | 9,216 / 1.773 | 0 / 0.0082 |
| Sand, camera inside (3,996) | 3,996 / 1.978 | 0 / 0.0125 |
| Plant section Z (9,216) | 9,216 / 1.341 | 0 / 0.0082 |

Capacity-fallback (`coarse_hit`) grains take the same one-line override and are exercised for coverage by the 112-check capacity suite; a cap-normal decode for that path was not added because that harness has no normal-image mode.

### Wall-adjacent sand (reviewer concern 1)

The level-2 stencil reaches ±4 cells, so sand near a vertical wall face reads the wall's density. Fixture: sand slope (0.6 rise per cell) piled against a full-height wall, decoded normals sampled at 20 per cell along five lines, binned by distance from the wall face. Mean signed tilt from the nominal slope normal, degrees:

| Distance from wall, cells | Baseline mean (max) | Fixed mean (max) | Change |
|---|---:|---:|---:|
| 0–1 | 34.7 (58.7) | 31.3 (58.7) | −3.5 |
| 1–2 | 12.6 (16.7) | 11.9 (12.7) | −0.7 |
| 2–3 | 5.8 (10.1) | 10.3 (12.1) | +4.5 |
| 3–4 | 0.3 (3.5) | 6.4 (8.2) | +6.2 |
| 4–5 | 4.3 (6.8) | 5.5 (6.2) | +1.3 |
| 5–6 | 7.4 (8.2) | 4.2 (6.2) | −3.1 |
| 6–7 | 7.6 (8.2) | 2.5 (3.5) | −5.1 |
| 7–8 | 6.2 (7.5) | 3.1 (4.2) | −3.1 |
| 8–9 | 3.6 (4.8) | 5.2 (6.2) | +1.6 |

The first two cells are dominated by the join geometry itself in both variants. The wide stencil adds up to 6.2° of mean tilt in the 2–4 cell band and removes 3–5° of the baseline's own stair-step bias beyond 5 cells. Decision: **no distance-to-wall fade now.** The added tilt is bounded, confined to a two-cell band, and no larger than the bias the baseline already carries on open slopes; a wall-distance field is not available in the shader, and a coarse/wide divergence guard would reintroduce ripple wherever the two stencils disagree periodically. If a later fixture shows the band is visible in the editor, the guard is the candidate to test.

### Wood and plant (reviewer concern 2)

Wood (smoothing 0.5) and plant (0.6) are also smoothed. Matched captures, same bytes and camera: a two-cell and a one-cell plank on posts, and a plant sphere. Wood: lit image **byte-identical** (0 changed bytes), decoded normals change by 0.03° mean and max. Plant: 18,904 of 3.24 M lit bytes change (max channel delta 23), mean lit byte 89.17 → 89.16, decoded normals change 0.05° mean, 6.0° max at the sphere's cell-scale bumps. Flat planks are unaffected; the plant sphere loses per-cell curvature accents on its bumps, which is the same trade recorded for sand. [Captures](powder-ripple-evidence/gpu/) `wood-plank-*`, `plant-sphere-*`.

## GPU evidence

Godot 4.6.3, Metal 4.0, Apple M5 Pro, always-on-top, VSync disabled. The machine was on battery in macOS Low Power Mode during every run: the display is capped at 60 Hz and the SoC is throttled, so frame p95 values sit near 16–20 ms and only paired original/candidate medians are meaningful. [Import log](powder-ripple-evidence/import.log) (assets were reimported before the visible runs).

`tests/milestone/render_powder_ripple_gpu.gd` renders frozen sand wedges at 0.35 and 0.6 rise per cell and a wall wedge control at 1200×900, native resolution, no spatial AA, lit by one directional light matching `light_dir`, with textures neutralized (`texture_tile` 1e5, zero `mat_grain`, `detail_strength` 1.0). It compares the immutable pre-fix fixture `tests/milestone/fixtures/voxel_opaque_ripple_baseline.gdshader` with the candidate on identical bytes and cameras, sampling five lines down each slope at 20 samples per cell (5,000–6,800 samples per case), and reports lit-luminance ripple (relative to mean) and decoded-normal ripple after a one-riser moving average. With the wall-adjacent, wood and plant fixtures the suite is **51 checks, zero failures** after the cap fix (the slope numbers below are unchanged from the first accepted run). [Metrics](powder-ripple-evidence/gpu/ripple-metrics.json), [run log](powder-ripple-evidence/gpu/run.log).

| Case | Lit ripple rms, baseline → fixed | Lit peak-to-peak | Normal ripple rms | Mean luminance |
|---|---:|---:|---:|---:|
| Sand, 0.35 rise per cell | 4.94% → 1.32% (27%) | 20.5% → 10.2% | 2.27° → 0.58° (25%) | 0.917 → 0.936 (+2.0%) |
| Sand, 0.6 rise per cell | 4.03% → 1.03% (26%) | 16.7% → 10.9% | 0.98° → 0.39° (40%) | 0.918 → 0.933 (+1.6%) |
| Wall control, 0.6 | 2.42% → 2.42% | identical | 0 → 0 | identical |

The wall control's lit and normal images are **byte-identical** between shaders (0 changed bytes; a baseline recapture also showed 0 bytes of frame-to-frame self-noise). Its residual 2.4% "ripple" is the real staircase of a crisp wall wedge, which is the intended crisp look, not a defect. The CPU model predicted a 5–7× curvature and 3.5× normal reduction; the GPU lit ratio is about 3.8× because the remaining lit ripple includes the unchanged AO taps and the residual level-1 curvature term, and pixel snapping along the sampled lines adds common-mode noise to both variants. The pre-declared 50% gates hold with margin; none were adjusted. Complete voxel readback matched the uploaded bytes after every case.

Matched sand cone, same bytes and camera: [baseline](powder-ripple-evidence/gpu/cone-baseline-lit.png), [fixed](powder-ripple-evidence/gpu/cone-fixed-lit.png). Slope captures: [0.35 baseline](powder-ripple-evidence/gpu/sand-shallow-baseline-lit.png), [0.35 fixed](powder-ripple-evidence/gpu/sand-shallow-fixed-lit.png), [0.6 baseline](powder-ripple-evidence/gpu/sand-repose-baseline-lit.png), [0.6 fixed](powder-ripple-evidence/gpu/sand-repose-fixed-lit.png), with the decoded-normal images alongside.

### Cost

`tests/milestone/powder_ripple_cost.gd` alternates original/candidate three times on a frozen 256 sand heap (2,863,384 sand cells) with a reservoir (413,646 water cells), 900×700, FXAA, VSync off, 30 warm-up plus 120 measured frame-post-draw intervals per sample. [cost.json](powder-ripple-evidence/cost/cost.json), [log](powder-ripple-evidence/cost/run.log).

| Pair | Original median | Candidate median | Paired difference |
|---|---:|---:|---:|
| 0 (original first) | 2.358 ms | 2.392 ms | +0.034 ms |
| 1 (candidate first) | 3.305 ms | 2.741 ms | −0.564 ms |
| 2 (original first) | 3.606 ms | 2.593 ms | −1.013 ms |

Under Low Power Mode the same shader's medians drift by more than 1 ms between repeats, so the paired differences (+0.03, −0.56, −1.01 ms) are within that drift and establish only that the change has **no measurable cost at this precision**; they do not establish a speedup. The candidate adds four level-2 fetches and six level-1 fetches per opaque hit. Physical bytes were exact; the captures differ on sand as intended (154,042 bytes, max channel delta 56).

### Regressions

Existing suites on the corrected candidate: extended surface normals/coverage **99 checks** (above); sprite section clipping **40 checks** ([log](powder-ripple-evidence/regressions/sprites.log)); physical capacity fallback **112 checks** ([log](powder-ripple-evidence/regressions/capacity.log)); all zero failures. The first accepted run's surface suite (60 checks) and its metrics remain in the same directory. The capacity suite's first attempt hit its 120-second watchdog after 97 passing checks on the throttled machine and was rerun unchanged; that watchdog exit is a load artifact, not a check failure.

```sh
godot --headless --path . --import
python3 tools/milestone/powder_ripple_reference.py
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_powder_ripple_gpu.gd -- grid=128 output_dir=/tmp/rendering-gpu/ripple128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/powder_ripple_cost.gd -- grid=256 output_dir=/tmp/rendering-gpu/ripple-cost256
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_surface_gpu.gd -- grid=128 output_dir=/tmp/rendering-gpu/surfaces128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_section_sprites_gpu.gd -- grid=128 output_dir=/tmp/rendering-gpu/sprites128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_capacity_gpu.gd -- grid=128 output_dir=/tmp/rendering-gpu/capacity128
```

## Limits

This removes lattice-frequency shading ripple on planar smoothed slopes. It does not remove the stair-step silhouette of the reconstructed isosurface, the 5–7° mean normal bias of that field on slopes, or texture/grain noise (which the milestone editor already scales down). Isolated single smoothed cells now shade as soft bumps, and one-cell ridges lose their per-cell curvature accent. The editor's default `detail_strength` of 0.18 already hid most of the curvature ripple, so the visible improvement is largest at full detail and in the normal-driven lighting; the editor keeps its current settings. No frame-rate claim follows from the throttled cost run.
