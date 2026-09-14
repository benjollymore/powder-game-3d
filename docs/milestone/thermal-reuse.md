# Reusing the center temperature in the fused thermal update

Explicitly decoding each cell's own temperature once improves the [first fused implementation](thermal-fused.md) while preserving every tested FP32 energy and diagnostic byte. At 256³, four steps per visible frame fall from **23.827 to 17.877 ms** (25.0% lower), with the same **192 MiB** steady logical GPU allocation. This remains an isolated stationary-conduction experiment, with no production heat coupling.

## Change and correctness

`reuse_heat.glsl` computes the center temperature and conductivity outside the face loop. Each face then decodes only its neighbor and passes the pair in canonical lower-index→upper-index order to the same precise transfer expression. The final gather retains +x,+y,+z,-x,-y,-z order and skips missing boundary faces. The shared `state_of` decoder and all original fused/two-pass shader sources remain unchanged. An adapter subclass selects the new heat/audit shaders; the first fused adapter's default kernel selection remains unchanged.

The result passes **89 GPU admission/batching checks**, **16 face-audit checks**, and the same 12 numerical fixtures and thresholds. **All 26 energy and all 26 diagnostic checkpoints are byte-identical to the first fused result**, including the 1000-step heterogeneous and mixed-material cases. Accordingly, numerical errors, conservation drift, phase plateaus and diffusion convergence equal the previously reported fused metrics. All three batch schedules remain byte-identical. [GPU log](evidence-thermal-gpu/reuse-gpu.log), [numerical metrics](evidence-thermal-gpu/reuse-metrics.json), [full comparison](evidence-thermal-gpu/reuse-comparison.json).

The audit again finds zero bit mismatches in 1260 shared-face comparisons and 26 `NoContraction` decorations. Initial nonzero-flow controls pass, including the mixed-material fixture's 151 nonzero faces after 1000 steps. [Face audit](evidence-thermal-gpu/reuse-face-pairs.log).

All three adapters reject the nine invalid timestep inputs on CPU (**27/27**). All seven compiled shaders have empty compute compilation errors (**7/7**). The first import attempt exposed Godot's failure to expand a nested include in this path; placing both includes directly in each shader fixes it. The failed import evidence is retained separately, and no numerical thresholds changed. [Admission](evidence-thermal-gpu/reuse-admission.log), [shader checks](evidence-thermal-gpu/reuse-shaders.log), [initial import error](evidence-thermal-gpu/reuse-shaders-first-failed.log).

## Paired timing

Same process, first fused→reuse then reuse→first fused; 0/1/4 steps per frame in reversed repeat order. Conditions remain Godot 4.6.3 / Metal 4.0 / Apple M5 Pro, always-on-top 1600×900 canvas, VSync off, 30 warmup + 240 measured frames, dt=1/60 s, half-volume 360/290 K synthetic PCM. A four-byte energy read drains GPU work before the timer ends. Allocation/reset, probes and capture remain outside timing. Diagnostics are not allocated, as both adapters' configuration records verify. [128³ log](evidence-thermal-gpu/reuse128.log), [256³ log](evidence-thermal-gpu/reuse256.log), [visible reuse capture](evidence-thermal-gpu/reuse-reuse-256.png).

| Grid | Steps/frame | First fused mean, repeats 0 / 1 | Reuse mean, repeats 0 / 1 |
| --- | --- | --- | --- |
| 128³ | 0 | 2.908 / 2.125 ms | 2.143 / 2.252 ms |
| 128³ | 1 | 2.715 / 2.206 ms | 2.361 / 2.464 ms |
| 128³ | 4 | 3.625 / 3.525 ms | 2.927 / 2.863 ms |
| 256³ | 0 | 2.935 / 2.223 ms | 2.421 / 2.411 ms |
| 256³ | 1 | 6.067 / 6.104 ms | 4.950 / 4.932 ms |
| 256³ | 4 | 23.827 / 23.828 ms | 17.878 / 17.875 ms |

At 256³ four-step frame p95 improves from 23.916/23.895 to 17.948/17.961 ms. Both variants produce the same probed interface energies, independently at both sizes and repeats. Their real heat exchange demonstrates that the timed work completed. No GPU runtime resource-leak/error diagnostics occurred. Small idle/single-step cases remain subject to visible-window scheduling noise; subtracting idle time is not a GPU pass measurement.

The new timing is close to the earlier two-pass 17.17–17.96 ms, while using one third of its storage. The two-pass solver was not rerun in this particular paired process, so this is context, not a claim of measured equivalence or superiority against it. The canvas still has no editor, voxel rendering, fluid solver, or other coupled physics, so these numbers are not integrated game-loop timings.

## Decision

Prefer explicit center reuse over the first fused variant for further low-storage stationary experiments: it is consistently faster in the substantial-work case and preserves all tested state bytes. Retain the first fused source/evidence as the comparison baseline. This result does not justify adding dense heat to the production game yet. A middle layout with a transient FP32 temperature field (16 B/cell steady rather than 12 or 36) may avoid decoding each neighbor repeatedly; that is a separate hypothesis requiring the same conservation and timing checks.

Reproduction after importing shaders, GPU commands serially:

```sh
godot --headless --path . -s res://tests/feasibility/thermal_gpu/shader_import.gd
godot --headless --path . -s res://tests/feasibility/thermal_gpu/admission.gd
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/thermal_gpu/run_gpu.gd -- thermal_variant=reuse
python3 tools/feasibility/thermal_gpu/evaluate.py --variant reuse
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/thermal_gpu/face_pairs.gd -- thermal_variant=reuse
python3 tools/feasibility/thermal_gpu/compare_results.py --first fused --second reuse
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/feasibility/thermal_gpu/reuse_bench.gd -- thermal_grid=128
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/feasibility/thermal_gpu/reuse_bench.gd -- thermal_grid=256
```
