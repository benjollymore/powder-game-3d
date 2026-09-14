# Surface-normal defect: verified cause and first fix

The dark speckles on otherwise flat walls and floors were reproducible **incorrect normals**, not missing physical cells. The first milestone rendering change fixes this surface defect and the view-dependent normals on section caps. It does not change simulation bytes, density generation, ray intersection positions, material appearance, or the physical grain/droplet/leaf representation.

## Cause and correction

The opaque shader bisects a density crossing four times, then selected a rigid face normal by asking which coordinate of the approximate hit was nearest an integer cell plane. Bisection leaves a small error along the ray. An unrelated tangential cell boundary can consequently be nearer than the true surface plane. A floor pixel gets a side-facing normal, affecting directional lighting, AO and sun-visibility sampling. Raising texture quality or disabling decorative grain cannot fix this geometry-derived error.

The correction chooses the strongest axis of the already computed local density gradient, with its outward sign. A flat density boundary consistently identifies the actual surface axis, independently of bisection-position error. Smooth materials continue to use their reconstructed normals and existing blend weights.

Separately, an initial ray hit inside the clipped volume used `-ray.direction` as its normal. This made a flat section look curved as the camera moved. At volume entry, the correction uses the actual ray/box entry axis and direction; the cap stays axis-aligned. The visual clip still leaves all physical state intact.

## Controlled evidence

A preserved pre-fix shader and shared include are under `tests/milestone/fixtures/`; they are used only by the regression harness. Baseline and fixed shaders render the same frozen bytes through the same camera and viewport. The test displays geometric normals as RGB emission with no lighting, textures, AA, upscaler or volume transparency to confound the diagnosis. This isolates the defect instead of hiding it with softer lighting.

At grid 128, 1200×900 and native internal resolution, each analytic face is sampled at 9,216 projected interior world points. Sampling excludes six reference cells at each edge so silhouette interpolation or another visible face cannot masquerade as the tested flat face. Rendered RGB is converted back to linear normal coordinates and compared with the known axis normal. A maximum vector error of 0.08 accommodates 8-bit image quantization; a wrong axis is approximately 1.41 away. Coverage also checks for missing/black pixels. These are interior samples, not a proof of every silhouette pixel or every possible material mixture.

| Case | Baseline wrong normals | Fixed wrong normals | Missing samples, baseline/fixed |
|---|---:|---:|---:|
| Floor, oblique | 61 | 0 | 0 / 0 |
| Floor, reverse angle | 56 | 0 | 0 / 0 |
| Floor, grazing angle | 194 | 0 | 0 / 0 |
| One-cell-thick sheet | 72 | 0 | 0 / 0 |
| Section X | 9,216 | 0 | 0 / 0 |
| Section Y | 9,216 | 0 | 0 / 0 |
| Section Z | 9,216 | 0 | 0 / 0 |

Fixed maximum normal error is 0.00817 in every case, consistent with image quantization. All seven complete GPU voxel readbacks exactly matched their original upload after both variants. The visible run completed **53 checks, zero failures**, with no script/shader errors. The metric is a surface correctness regression, not a performance benchmark.

[Raw metrics](rendering-evidence/surface-metrics.json), [visible GPU log](rendering-evidence/surface-run.log), and [parser log](rendering-evidence/parser.log).

Oblique floor, baseline versus fixed:

![Baseline floor normal speckles](rendering-evidence/floor-oblique-baseline-normals.png)

![Fixed floor constant normal](rendering-evidence/floor-oblique-fixed-normals.png)

Section Z, baseline versus fixed:

![Baseline section view-facing normals](rendering-evidence/section-z-baseline-normals.png)

![Fixed section constant normal](rendering-evidence/section-z-fixed-normals.png)

The remaining ten normal captures are in the same evidence directory. Inspection of the full captures confirms the visible flat regions became uniform, rather than relying on an average pixel statistic alone.

## Reproduction and limits

```sh
godot --headless --editor --path . --import --quit
godot --headless --path . --check-only -s res://tests/milestone/render_surface_gpu.gd
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_surface_gpu.gd -- grid=128
```

The visible process ran on Apple M5 Pro / Metal 4.0 / Godot 4.6.3. Keep its window visible during readbacks. This fix is independent of the simulation worker's foam timing and scheduling changes: no compute shader or simulator API changed.

Remaining work: matched shaded-material captures; mixtures and silhouette/thin-feature coverage; section behavior for liquids/gases/sprites; optional paint-first presentation setup. The evidence does not establish elimination of every kind of visual noise, a final high-fidelity art direction, or an improvement in fluid physics.
