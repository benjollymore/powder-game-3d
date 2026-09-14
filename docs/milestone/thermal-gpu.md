# FP32 stationary thermal feasibility

The isolated binary64 thermal reference survives this FP32 GPU implementation within the numerical targets declared before execution. This is a stationary, insulated, full-cell conduction experiment with latent enthalpy. It does not add temperature, melting, combustion energy, or heat transport to the production voxel simulation.

## Representation and algorithm

Each cell stores total enthalpy in joules relative to the reference's 273.15 K origin; negative relative energy is valid when absolute temperature remains positive. Materials provide density, conductivity, solid/liquid heat capacities, melting temperature, latent heat and specific enthalpy at melting. Full equal cubes have mass `density * dx³`. Material IDs and geometry stay fixed throughout each fixture.

One pass decodes temperature/phase and computes each positive-direction face transfer once: `q = dt * harmonic_conductivity * dx * (T_neighbor - T_cell)`. A second pass gathers the same stored FP32 transfer with opposite signs into ping-pong energy. This avoids float atomics and asymmetric recomputation. Local energy addition still rounds, so global energy is not bit-exactly conserved; drift is measured rather than presumed zero.

The adapter receives a CPU-validated conservative explicit bound, `min(cell_mass * min(cp_solid, cp_liquid) / sum(face_conductance))`. It rejects nonpositive/nonfinite/underflowing timesteps and checks the actual FP32 encoded timestep against that bound. The nine CPU admission checks include a binary64 `0.1` timestep whose upward-rounded FP32 value exceeds a `0.1` bound. Invalid requests leave energy and tick counts unchanged. Fixture steps use margin below the bound; production admission would need bounds validated against its quantized coefficients, changing fill fractions and material transitions.

## Numerical evidence

The fixtures are generated directly with `thermal_reference.py`. Coefficients are synthetic, not calibrated real materials. Targets were set before the first GPU run: maximum temperature error 0.005 K, phase-fraction error 1e-5, relative energy drift 2e-5, and retention of the CPU cosine-diffusion refinement criteria (>3× error reduction per doubling, final RMS <0.001 K). No targets were relaxed.

All **80 GPU admission/batching checks**, **nine CPU admission checks**, and the **12 original CPU thermal-reference tests** pass. The numerical evaluator accepts all 11 fixtures, including six-face hotspot exchange, heterogeneous conduction, below-reference enthalpy, equilibrium, latent phase transition, insulated interfaces and diffusion convergence. [GPU log](evidence-thermal-gpu/gpu-first.log), [admission](evidence-thermal-gpu/admission.log), [CPU reference](evidence-thermal-gpu/cpu-reference.log), [numerical evaluation](evidence-thermal-gpu/evaluation-first.log), [full metrics](evidence-thermal-gpu/metrics.json).

| Measurement | Observed result |
| --- | --- |
| Largest temperature error against binary64 checkpoints | 9.06e-5 K |
| Largest liquid-fraction error | 1.19e-7 |
| Largest relative energy drift | 2.02e-6, heterogeneous 1000-step case |
| Absolute drift in that case | +0.0302124 J |
| Isothermal and insulated fixtures | Zero energy drift after 1000 steps |
| Conducting phase-change fixture | Four sampled states exactly at 300 K during partial melting |
| Static latent interval | Nine interior fractional states exactly at 300 K |
| Batches `[1]`, `[3]`, `[7,2,5,1,9]` | Matching FP32 energy/state values after the same 80 ticks |

Relative drift uses the sum of absolute initial **FP32** cell energies as its denominator. This separates initial binary64→FP32 conversion from subsequent integration drift and remains meaningful for negative relative enthalpy. Full-state readbacks check lengths and finite values before numerical comparison. The original reference's explicit unsafe-step control is retained; the GPU adapter refuses oversized steps before dispatch.

The insulated cosine fixture retains convergence at 16/32/64 cells: GPU RMS errors are **0.00161825 / 0.000505985 / 0.000128698 K**, refinement ratios **3.20 / 3.93**. The corresponding binary64 reference errors are 0.00161038 / 0.000506480 / 0.000126599 K. This supports the tested spatial/time refinement range; it does not establish accuracy after arbitrary refinement or millions of ticks.

## Memory and visible dispatch benchmark

The straightforward prototype allocates **36 bytes per cell**, excluding small material tables, driver overhead and CPU staging: two energy buffers (8 B), one padded three-face transfer buffer (16 B), material IDs (4 B), and diagnostic temperature/fraction output (8 B). This is **72 MiB at 128³**, **576 MiB at 256³**. A substantial part is reusable/derived scratch, not a proposed permanent production particle record.

Benchmark conditions: Godot 4.6.3, Metal 4.0 / Apple M5 Pro, visible always-on-top 1600×900 canvas, VSync disabled, 30 warmup + 240 measured frames. The lattice starts half at 360 K and half at 290 K using the synthetic phase-change material, with `dx=0.01 m`, `dt=1/60 s`. Idle/one/four steps per frame run twice in reversed order. A final four-byte energy read drains queued GPU work before timing stops. Allocation, reset, screenshots and interface probes are outside timing. [128³ log](evidence-thermal-gpu/bench128.log), [256³ log](evidence-thermal-gpu/bench256.log), [visible 128³ canvas](evidence-thermal-gpu/bench-128.png), [visible 256³ canvas](evidence-thermal-gpu/bench-256.png).

| Grid | Steps/frame | Drained whole-frame mean, repeat 0 / 1 | Frame p95, repeat 0 / 1 |
| --- | --- | --- | --- |
| 128³ | 0 | 2.925 / 2.090 ms | 8.594 / 6.569 ms |
| 128³ | 1 | 2.515 / 2.392 ms | 6.596 / 6.179 ms |
| 128³ | 4 | 2.784 / 2.864 ms | 8.273 / 8.190 ms |
| 256³ | 0 | 3.000 / 2.133 ms | 8.469 / 6.696 ms |
| 256³ | 1 | 4.673 / 4.742 ms | 7.242 / 8.147 ms |
| 256³ | 4 | 17.404 / 17.440 ms | 17.754 / 17.818 ms |

The small 128³ cost is obscured by visible-window scheduling noise: the first idle repeat is slower than the one-step repeat. Do not infer a negative dispatch cost or derive isolated GPU pass timings by subtracting these means. At 256³, four thermal steps consistently consume about 17.4 ms of inclusive frame time, making this dense implementation an expensive additional subsystem. These values cannot simply be added to editor timings: this canvas does not run the editor, fluid solver, or voxel renderer.

Probes verify real heat exchange and identical repeated outcomes: interface energies change from 246.850006/16.850000 J to 224.363098/38.778561 J after 270 steps, or 192.222366/84.776695 J after 1080 steps, identically at both benchmark sizes. No resource-leak diagnostics occurred.

## What this establishes and leaves open

FP32 enthalpy is numerically credible for these stationary fixtures, including a latent plateau. The stored-face implementation provides a clear conservative reference for a lower-memory variant. It is not yet an acceptable default addition to a fast dense 256³ game loop: scratch memory and full-grid work are substantial.

Moving liquid/powder must transport accepted mass and its enthalpy together; partial fill changes face geometry and stability limits. Mixed species, pressure work, phase-dependent density, radiation, boundary heat exchange and combustion source accounting are absent here. A production integration must define those contracts and preserve the fixed simulation cadence, reset/snapshot behavior and energy ledger. The GPU kernels do not bind any production buffers or alter existing scene files.

Reproduction, GPU commands serially:

```sh
python3 tools/feasibility/thermal_gpu/generate_cases.py
godot --headless --path . --import
godot --headless --path . -s res://tests/feasibility/thermal_gpu/admission.gd
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/thermal_gpu/run_gpu.gd
python3 tools/feasibility/thermal_gpu/evaluate.py
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/feasibility/thermal_gpu/bench.gd -- thermal_grid=128
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/feasibility/thermal_gpu/bench.gd -- thermal_grid=256
```
