# Thermal layout decision: cache temperature, recompute faces

For the tested stationary heat workload, a **16 B/cell layout with cached temperature** gives the strongest storage/throughput tradeoff of the three final candidates. At 256³, four steps per visible frame take **13.195/13.205 ms**, versus **17.045/17.839 ms** for the original stored-face reference and **17.873/17.879 ms** for center reuse. It allocates **256 MiB** of steady logical GPU buffers, compared with 576 MiB and 192 MiB respectively. All original numerical gates pass, and its tested energy/state bytes equal the center-reuse variant.

This concludes the bounded stationary-kernel tuning experiment. The candidate remains isolated: it does not add heat to production voxels or demonstrate heat carried by moving material.

## Final layout

The first pass decodes one FP32 temperature per cell from immutable enthalpy. After a barrier, the second pass reads that temperature field and recomputes each of six face transfers with canonical lower-index→upper-index operands. Each invocation gathers its own signed transfers and writes only its own next energy. The same constrained arithmetic and +x,+y,+z,-x,-y,-z gather order are retained. There are no float atomics or stored face-transfer records.

The allocation is energy ping-pong 8 B + material IDs 4 B + temperature scratch 4 B per cell. That is **32 MiB at 128³ / 256 MiB at 256³**, excluding small coefficient tables, driver resources and CPU staging. Inspecting a full temperature/fraction snapshot lazily adds and retains 8 B/cell, making the inspected allocation **48/384 MiB** until close. No benchmark inspection buffers are allocated.

Temperature is derived scratch, not authoritative state. It is refreshed before every heat update and face audit. Reset replaces energy; the next update refreshes the entire temperature cache before reading it. A full snapshot decodes the current energy separately, avoiding the cache's one-update age after a gather. This distinction matters if a later renderer or coupled solver consumes temperature.

The original two-pass, first fused, and center-reuse shader sources remain unchanged. New `cached_gpu.gd`, `decode_temperature.glsl`, `cached_heat.glsl`, and the matching audit/common files implement this candidate. Existing experiment harnesses merely add a selectable variant. The stored-face reference includes its original always-written diagnostic buffer; the timing comparison is against that exact implementation, not every possible optimized two-pass algorithm.

## Numerical verification

**89 GPU checks**, **16 face-audit checks**, **36 CPU invalid-step checks** across four adapters, and **10 shader-import checks** pass. The same expanded 12 fixtures and unchanged thresholds apply. **All 26 energy and 26 diagnostic checkpoint hashes match center reuse exactly**, including heterogeneous and mixed-material 1000-step runs. The three batch schedules remain byte-identical. [GPU checks](evidence-thermal-gpu/cached-gpu.log), [numerical metrics](evidence-thermal-gpu/cached-metrics.json), [exact comparison](evidence-thermal-gpu/cached-comparison.json), [CPU admission](evidence-thermal-gpu/cached-admission.log), [shader imports](evidence-thermal-gpu/cached-shaders.log).

Consequently the measured worst temperature error remains 9.8538e-5 K, liquid-fraction error 9.2940e-7 and relative energy drift 6.1068e-7. The exact 300 K latent plateau and diffusion refinement ratios 3.2023/3.9319 are unchanged. This equivalence is evidence for the tested compiler/device and fixtures, not a universal replay guarantee.

The face audit again checks **1260 pairs with zero bit mismatches**, including nonzero initial flow and 151 nonzero mixed-material faces at step 1000. The compiled gather now has 13 `NoContraction` decorations; decoding moved into its own shader using the unchanged precise decoder. [Face audit](evidence-thermal-gpu/cached-face-pairs.log).

## Same-process comparison

The visible benchmark runs two-pass→reuse→cached, then cached→reuse→two-pass, allocating and closing each variant separately. Within each allocation, idle/one/four-step cases run in forward then reversed order. Godot 4.6.3, Metal 4.0, Apple M5 Pro; always-on-top 1600×900 canvas, VSync off; 30 warmup + 240 measured frames; `dt=1/60 s`; homogeneous synthetic PCM split between 360/290 K. A four-byte energy read drains queued GPU work before timing ends. Allocation/reset, interface probes and screenshots remain outside timing. [Full log](evidence-thermal-gpu/cached256.log), [visible cached canvas](evidence-thermal-gpu/cached-cached-256.png), [two-pass canvas](evidence-thermal-gpu/cached-two-pass-256.png), [reuse canvas](evidence-thermal-gpu/cached-reuse-256.png).

| Variant | Steady allocation at 256³ | Idle mean, repeats 0 / 1 | One-step mean, repeats 0 / 1 | Four-step mean, repeats 0 / 1 | Four-step p95, repeats 0 / 1 |
| --- | --- | --- | --- | --- | --- |
| Stored-face reference | 576 MiB | 2.886 / 2.262 ms | 4.675 / 4.871 ms | 17.045 / 17.839 ms | 17.481 / 18.187 ms |
| Fused center reuse | 192 MiB | 2.225 / 2.022 ms | 4.790 / 4.980 ms | 17.873 / 17.879 ms | 17.946 / 17.953 ms |
| Cached temperature | 256 MiB | 2.090 / 1.820 ms | 3.969 / 3.921 ms | 13.195 / 13.205 ms | 13.317 / 13.342 ms |

Across the two four-step repeats, cached temperature has **24.3% lower inclusive frame time than the original reference** and **26.2% lower than center reuse**. It saves 320 MiB against the reference, at a 64 MiB cost against center reuse. The advantage persists in both ordering directions. Actual interface probes verify heat exchange, repeatable results and equal cached/reuse values after 270 and 1080 completed steps. No runtime errors or resource-leak diagnostics occur.

These are drained **whole-frame canvas timings**, not isolated GPU pass timings or integrated editor costs. Idle/small cases still show window-scheduling noise. The benchmark's large grid has homogeneous material coefficients and a simple planar temperature interface; the numerical suite tests heterogeneous materials only on small grids. Timing this candidate at 128³ was not part of the final lease, so the 128³ memory figure is an allocation calculation, not a new timing claim. The earlier 128³ measurements remain in the prior reports.

## Handoff

Use the cached-temperature candidate as the stationary GPU reference for the next coupling experiment. Keep center reuse as the lower-memory fallback and the stored-face implementation as an independent numerical reference. Stop kernel tuning here; no production default changes follow from this result alone.

The next architectural question is how accepted material transfers carry mass and enthalpy together. Full-cell fixed-density conduction does not establish partial-fill face geometry, changing stability bounds, mixed-species energy, phase-dependent volume, combustion sources or boundary work. Those contracts matter more than another small pass optimization. A later implementation must also define reset/snapshot ownership and deterministic scheduling relative to voxel motion.

Reproduction, GPU commands serially:

```sh
godot --headless --path . --import
godot --headless --path . -s res://tests/feasibility/thermal_gpu/shader_import.gd
godot --headless --path . -s res://tests/feasibility/thermal_gpu/admission.gd
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/thermal_gpu/run_gpu.gd -- thermal_variant=cached
python3 tools/feasibility/thermal_gpu/evaluate.py --variant cached
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/thermal_gpu/face_pairs.gd -- thermal_variant=cached
python3 tools/feasibility/thermal_gpu/compare_results.py --first reuse --second cached
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/feasibility/thermal_gpu/cached_bench.gd -- thermal_grid=256
```
