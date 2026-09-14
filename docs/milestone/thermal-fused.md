# Lower-storage stationary heat experiment

This experiment compares a fused update with the unchanged [two-pass FP32 reference](thermal-gpu.md). Both solve stationary, insulated, full-cell conduction with latent enthalpy. Neither binds production voxel state. The fused form meets the same numerical targets and cuts steady allocation by two thirds, but is slower on the tested GPU. Retain it as a storage tradeoff, not a speed improvement: at 256³ and four steps per frame it took about 23.87 ms versus 17.17–17.96 ms for the reference.

## Storage and arithmetic

The fused update keeps two FP32 energy buffers and one uint material-ID buffer: **12 B/cell**, versus **36 B/cell** for the reference. It removes the stored face-transfer buffer and defers diagnostic temperature/fraction allocation until inspection. This reduces steady logical allocation from 72 to 24 MiB at 128³, and from 576 to 192 MiB at 256³. Calling `snapshot()` adds 8 B/cell and retains it until `close()`, yielding 20 B/cell (40/320 MiB) for an inspected instance. Small coefficient tables, driver resources and CPU staging are excluded. The benchmark never requests that diagnostic allocation.

Each cell recomputes its six face transfers directly from immutable old energy, then writes only its own new energy. Both neighbors evaluate a shared face in canonical lower-index→upper-index order, so opposite directions do not reverse the temperature subtraction or the conductivity operands. Summation follows the reference's +x,+y,+z,-x,-y,-z order. There are no float atomics. One dispatch/barrier replaces two per step, at the cost of duplicated face arithmetic and neighbor temperature decoding.

The common shader uses `precise` inside both the enthalpy decoder and the transfer function, as well as in the final gather. This is deliberate: the qualifier's operation constraints do not propagate into called functions automatically. The compiled heat shader is inspected for SPIR-V `NoContraction` decorations. These prevent contraction/reassociation of the marked arithmetic; they do not establish universal cross-device bit identity. [GLSL specification §4.9](https://registry.khronos.org/OpenGL/specs/gl/GLSLangSpec.4.60.html), [SPIR-V specification](https://registry.khronos.org/SPIR-V/specs/unified1/SPIRV.html).

Equal and opposite face transfers still undergo separate rounded cell-energy additions. Global conservation must therefore be measured, even when the face values have identical bits. The original two-pass kernels intentionally retain their original compiler freedom, so exact cross-variant equality is measured separately from each variant's numerical acceptance.

## Verification contract

The original targets remain unchanged: maximum temperature error 0.005 K against binary64, liquid-fraction error 1e-5, relative energy drift 2e-5, cosine-refinement ratios >3 and final RMS <0.001 K. Both variants run the same expanded 12-case cohort. The added 7×5×3 case mixes three materials, temperatures below/above the enthalpy reference, and initial latent fractions for 1000 steps. Previously recorded 11-case results remain in their original files; the new runs use `baseline-` and `fused-` prefixes.

Batching compares SHA-256 hashes of the actual FP32 energy and diagnostic byte arrays after the same 80 steps in batches of 1, 3 or [7,2,5,1,9]. Invalid timestep admission is checked in both variants. A separate diagnostic shader uses the same canonical transfer function to write both evaluations of every shared face for four nonuniform small fixtures, initially and after 1000 steps. The test compares uint bit patterns, requires initial nonzero transfers, and verifies the compiled heat shader retains contraction constraints. This is direct evidence for the tested compiler/device and fixtures, not a general compiler proof.

## Measured correctness

Godot 4.6.3 / Metal 4.0 on Apple M5 Pro passed **89 GPU checks per variant**, **16 face-audit checks**, **18 CPU admission checks** and the **12 original CPU thermal-reference tests**. Both 12-case numerical evaluations pass without relaxed targets. [Baseline evaluation](evidence-thermal-gpu/baseline-evaluation.log), [fused evaluation](evidence-thermal-gpu/fused-evaluation.log), [face audit](evidence-thermal-gpu/face-pairs-gpu.log), [admission](evidence-thermal-gpu/fused-admission.log), [CPU reference](evidence-thermal-gpu/fused-cpu-reference.log).

| Metric across all sampled checkpoints | Two-pass | Fused |
| --- | --- | --- |
| Maximum temperature error vs binary64 | 1.0593e-4 K | 9.8538e-5 K |
| Maximum liquid-fraction error | 1.6447e-6 | 9.2940e-7 |
| Maximum relative energy drift | 2.0152e-6 | 6.1068e-7 |
| Heterogeneous 1000-step final drift | +0.0302124 J | −0.00915527 J |
| Mixed three-material 1000-step final drift | −0.00665295 J | −0.00620282 J |
| Diffusion RMS at 16/32/64 cells | .00161825 / .000505985 / .000128698 K | .00161732 / .000505053 / .000128449 K |
| Diffusion refinement ratios | 3.1982 / 3.9316 | 3.2023 / 3.9319 |

The face audit found **zero bit mismatches in 1,260 shared-face comparisons**, initially and after 1000 steps, and counted **26 NoContraction decorations** in the compiled heat shader. Initial fields have nonzero flow; two settle to zero by step1000, while the other two retain nonzero transfers. The mixed-material case still has 151 nonzero faces at step1000. Both solvers maintain the exact 300 K latent plateau in all 28 sampled partially molten states (four conducting, nine static, fifteen mixed-material). Both are byte-exact across the three tested batch schedules.

Cross-variant equality is different: **12/26 energy checkpoints and 5/26 diagnostic checkpoints have identical bytes**. The largest differences between variants are 0.0005341 J per cell, 0.0001526 K and 7.1526e-7 liquid fraction. Even equal-energy equilibrium fields can have a one-ULP diagnostic difference because the constrained decoder rounds differently. These differences are small against the declared targets, but the variants must not be advertised as interchangeable bitwise replay implementations. [Detailed cross-variant comparison](evidence-thermal-gpu/comparison.json).

## Visible A/B timing

The same process allocates/runs/closes each variant in order two-pass→fused, then fused→two-pass. Within each allocation it tests 0/1/4 steps per frame, reversed on the second repeat. Conditions match the baseline: always-on-top 1600×900 visible canvas, VSync off, 30 warmup + 240 measured frames, dt=1/60 s, half-volume 360/290 K PCM. A four-byte energy read drains queued GPU work before timing stops. Reset/allocation, captures and interface probes are outside the timed interval. The canvas does **not** run the production editor, voxel renderer or fluid solver. [128³ log](evidence-thermal-gpu/compare128.log), [256³ log](evidence-thermal-gpu/compare256.log), [two-pass capture](evidence-thermal-gpu/compare-two-pass-128.png), [fused capture](evidence-thermal-gpu/compare-fused-256.png).

| Grid | Steps/frame | Two-pass drained mean, repeats 0 / 1 | Fused drained mean, repeats 0 / 1 |
| --- | --- | --- | --- |
| 128³ | 0 | 3.332 / 2.251 ms | 1.954 / 2.284 ms |
| 128³ | 1 | 2.895 / 2.541 ms | 2.371 / 2.455 ms |
| 128³ | 4 | 2.790 / 2.819 ms | 3.556 / 3.443 ms |
| 256³ | 0 | 3.252 / 2.146 ms | 2.105 / 2.121 ms |
| 256³ | 1 | 4.746 / 4.803 ms | 6.116 / 6.132 ms |
| 256³ | 4 | 17.171 / 17.964 ms | 23.877 / 23.872 ms |

At 256³, fused four-step p95 is 23.939/23.952 ms versus two-pass 17.570/18.302 ms. The repeated four-step means are about **36% slower** despite the 384 MiB allocation saving. Small/idle cases show window-scheduling noise; subtracting their means does not yield reliable GPU pass timings. Actual interface probes confirm completed heat exchange and repeated within-variant results at both grid sizes; slight cross-variant differences agree with the numerical comparison. No resource-leak diagnostics occurred.

## Decision and limits

Accept the fused representation as a numerically credible lower-memory reference for this device and fixture range; **reject its present implementation as a throughput optimization**. Recomputing faces trades buffer traffic for redundant decoding/arithmetic, and the measured GPU favors the stored-face approach here. A bounded followup can explicitly reuse each center temperature, or test a middle-storage layout that materializes temperature without storing all faces. Preserve this slower result and the original two-pass reference when comparing those options.

There is still no moving mass, mixed-cell geometry, heat-source ledger, dynamic coefficient change, combustion, pressure work or production coupling. The same explicit stability constraint applies; this experiment does not permit larger timesteps. The lower drift observed here does not establish a universal accuracy advantage, and no cross-device reproducibility claim is made.

## Reproduction

Run visible GPU commands serially, with other GPU experiments stopped:

```sh
python3 tools/feasibility/thermal_gpu/generate_cases.py
godot --headless --path . --import
godot --headless --path . -s res://tests/feasibility/thermal_gpu/admission.gd
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/thermal_gpu/run_gpu.gd -- thermal_variant=baseline
python3 tools/feasibility/thermal_gpu/evaluate.py --variant baseline
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/thermal_gpu/run_gpu.gd -- thermal_variant=fused
python3 tools/feasibility/thermal_gpu/evaluate.py --variant fused
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/thermal_gpu/face_pairs.gd
python3 tools/feasibility/thermal_gpu/compare_results.py
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/feasibility/thermal_gpu/compare_bench.gd -- thermal_grid=128
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/feasibility/thermal_gpu/compare_bench.gd -- thermal_grid=256
```
