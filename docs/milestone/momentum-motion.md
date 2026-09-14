# FP32 PIC/APIC transfer plus particle motion

The isolated FP32 PIC/APIC transfer-and-advection implementation passes all eight numerical fixtures without relaxing the predeclared gates below. APIC preserves the tested moving clouds' total angular momentum closely, while PIC supplies the expected dissipative negative control. The original zero-time binary64 transfer reference remains unchanged. No pressure, stress, fluid incompressibility, forces, collisions, or production coupling is included.

## Acceptance criteria declared before GPU execution

Tests use SI units, quadratic 3×3×3 B-spline support, and explicit `x_new=x_old+dt*v_new` advection after a PIC/APIC round trip. APIC angular momentum and represented kinetic energy include the affine matrix contribution `D=dx²/4 I`. A rotating initial cloud is force-free; it is not expected to trace rigid circular trajectories without a centripetal force. The binary64 comparison executes this same discrete method, not a different analytic fluid model.

- Every particle mass byte must remain unchanged. Grid mass relative error must be at most 2e-6.
- Linear-momentum error versus the initial state: norm ≤ `2e-5 * sum(m*|v_initial|) + 1e-7 kg m/s`.
- APIC total angular-momentum error: norm ≤ `3e-5 * sum(m*(|r|*|v| + D*|C|_F)) + 1e-8 kg m²/s`, using a fixed initial mass centroid as origin.
- Maximum particle position error versus binary64 after each sampled checkpoint: 5e-5 m; velocity error 3e-4 m/s; individual affine coefficient error 5e-3 s⁻¹.
- PIC general angular-momentum loss is measured against binary64 and reported as a negative control, not required to conserve. Its angular disagreement with binary64 uses the APIC-sized tolerance above.
- Represented kinetic-energy change and PIC/APIC dissipation are reported separately. A floating-point implementation is not allowed more than `2e-5*initial_energy + 1e-9 J` energy excess over the matching binary64 checkpoint; no energy-conservation claim is required of dissipative transfers.
- Identical ordered step schedules in batches 1, 3 and irregular groups must yield identical particle/status bytes within a variant. Timestep must be positive, finite and FP32-representable.

Boundary admission requires the entire quadratic kernel support both initially and at every candidate advected position: `base=floor(x/dx-0.5)`, `base>=0`, `base+2<shape` on each axis, evaluated by the GPU's actual FP32 arithmetic. If any particle is invalid or nonfinite, the **whole candidate step is rejected without modifying authoritative particles**, and later queued steps remain halted until reset. No kernel clipping, clamping, wall impulse or escaped-particle deletion is permitted. Boundary fixtures stay away from rounding ties so CPU and GPU admission decisions can be compared directly.

A gather-per-node P2G loops over every particle. This is intentionally acceptable only for tiny feasibility fixtures and is not a scalable implementation or performance claim.


## Method and admission implementation

Each step performs gather-per-node particle→grid transfer, grid→particle transfer, and candidate position update. Quadratic support uses the same tensor-product weights as [the unchanged binary64 reference](../../tools/feasibility/momentum_reference.py). APIC carries a 3×3 affine velocity matrix in addition to center velocity. The finite-step wrapper uses explicit `x += dt*v_new`; it does not add an unrecorded force to preserve rigid rotation.

All transfer reads use immutable old particles. Candidate particles live in a separate buffer. Each commit invocation scans the candidate validity flags; it copies its candidate only when all particles are valid. One invocation owns the accepted-step/rejection counters. Compute barriers separate every pass. Thus a boundary failure rejects the entire step before any authoritative particle changes. The status remains halted for the rest of a submitted batch and future submissions until reset. The public `advance` return value describes host submission admission; only synchronized GPU status/readback establishes how many steps actually completed.

An initial validation pass checks actual FP32 support and finite state before transfer. PIC requires explicitly zero affine input. CPU admission rejects nonpositive/nonfinite/unrepresentable timesteps and negative step counts. Host fixtures provide positive representable spacing and valid grid dimensions. This is a small reference interface, not production input/schema hardening.

All particles use full support on a 10³ grid with dx=0.1 m. The seven cloud fixtures contain 27 unequal-mass particles; the boundary fixture contains two separated particles. Translation, rotating initial velocity, non-affine velocity and general affine fields run for 100 steps (dt=0.002 s, or 0.001 s for non-affine). A boundary particle starting at x=0.823 m moving at 0.1 m/s accepts two dt=0.1 s steps, then rejects the third when its candidate lacks support. The second particle also remains unchanged on that rejected step. Starting at x=0.01 m fails initial support admission. These positions avoid exact support-boundary rounding ties.

## Results

Godot 4.6.3 / Metal 4.0 / Apple M5 Pro passes **80 GPU logical checks**, **11 CPU timestep/shader-import checks**, and **14 binary64 tests** (the existing 10 zero-time tests plus 4 finite-motion tests). All eight numerical evaluations pass their original limits. No runtime errors or resource-leak diagnostics occur. [GPU log](evidence-momentum-gpu/gpu-first.log), [numerical evaluation](evidence-momentum-gpu/evaluation-first.log), [complete metrics](evidence-momentum-gpu/metrics.json), [CPU tests](evidence-momentum-gpu/cpu-reference.log), [admission/shader checks](evidence-momentum-gpu/admission.log).

| Measurement across sampled checkpoints | Worst observed |
| --- | --- |
| Particle mass | Exact original FP32 bytes in every case |
| Grid mass relative error | 5.14e-8 |
| Position disagreement with binary64 | 1.86e-6 m |
| Analytic free-translation position error | 1.87e-6 m |
| Velocity disagreement with binary64 | 4.71e-6 m/s |
| Affine coefficient disagreement | 1.84e-5 s⁻¹ |
| Linear momentum drift | 7.18e-7 kg m/s, within its 1.52e-6 scaled bound |
| APIC total angular drift | 1.24e-7 kg m²/s, in near-zero-spin translation; within 2.51e-7 bound |
| APIC rotating-cloud angular drift | 3.04e-8 kg m²/s |

Momentum is evaluated around a fixed initial mass centroid, with the affine rotational contribution included. PIC's angular loss is not mislabeled as FP32 error: its disagreement with the corresponding binary64 loss remains within tolerance. Grid mass and grid↔particle momentum consistency are independently evaluated from grid readbacks. All metrics use synchronized GPU data rather than requested tick counts.

The non-affine APIC and boundary fixtures also run in batches 1, 3 and [7,2,5,1,9]. Particle hashes and the complete GPU status arrays match exactly. The boundary fixture remains at two accepted steps after five attempted steps; its third and fifth checkpoints have identical particle bytes to the last accepted second step. Invalid timestep submissions do not change particles or GPU status.

## Energy decay is a separate result

Represented energy includes both `½m|v|²` and `½m D ||C||²`. Reporting only center kinetic energy would omit APIC's stored subcell motion. The following values are retained fractions after 100 steps:

| Initial field / transfer method | Represented energy retained, GPU | Binary64 | Angular momentum retained, GPU |
| --- | --- | --- | --- |
| Translation / PIC | 1.00000189 | 1.00000000 | Near-zero initial angular momentum |
| Translation / APIC | 1.00000201 | 1.00000000 | Near-zero initial angular momentum |
| Rotation / PIC | 1.59e-15 | 2.77e-28 | 1.55e-14 |
| Rotation / APIC | 0.999489405 | 0.999494509 | 0.999997381 |
| Non-affine / PIC | 0.056993643 | 0.056993492 | 2.12e-5 |
| Non-affine / APIC | 0.066131684 | 0.066131400 | 0.999976128 |
| General affine / APIC | 0.999501236 | 0.999511959 | 0.999995890 |

PIC nearly erases the rotating cloud in this transfer-heavy fixture. APIC retains its angular momentum but is not energy-exact during finite motion. Both methods strongly dissipate non-affine content here; APIC retaining angular momentum does not imply that it retains arbitrary fine motion. The tiny positive translation energy drift is measured and below the declared excess allowance.

## Decision and limits

The result supports APIC's richer per-particle velocity/affine state as a credible candidate for preserving bulk rotation and affine motion in a future mobile-material subsystem. It does not establish fluid behavior: there is no pressure projection, constitutive stress, density constraint, free-surface treatment, collision, friction, or coupling to voxel structures. A force-free rotating initial field is not a rigid body and should not be sold as one.

The gather implementation loops over all particles for every grid node and scans all candidate flags for every commit particle. It is deterministic and convenient for tiny validation fixtures; it is deliberately unsuitable as a scalable particle solver. No throughput measurement or production performance claim is made. FP32 error is measured only over these 100-step trajectories and this device, not arbitrary long runs or platforms. There is no gravity and therefore no hidden external impulse or torque ledger.

The next useful extension is a declared material/force/boundary contract with mass, impulse, torque and energy accounting, followed by a scalable transfer strategy. Production integration would additionally need authored/runtime snapshot schemas for positions, velocities, affine matrices, mass and any thermal fields. The current four-byte CA record cannot represent this state by itself.

Reproduction, visible GPU test serially under the shared lease:

```sh
python3 tools/feasibility/momentum_gpu/generate_cases.py
python3 -m unittest tests.feasibility.test_momentum_reference tests.feasibility.test_momentum_motion
godot --headless --path . --import
godot --headless --path . -s res://tests/feasibility/momentum_gpu/admission.gd
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/momentum_gpu/run.gd
python3 tools/feasibility/momentum_gpu/evaluate.py
```
