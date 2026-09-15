# FP32 external mechanics: gravity and a plane constraint on PIC/APIC motion

The isolated FP32 mechanics stage declared in [the experiment plan](mechanics-experiment-plan.md) passes every predeclared numerical gate on all five fixtures without relaxing any bound. Uniform gravity reaches the particles as the requested impulse and the discrete analytic centre-of-mass trajectory. A stationary frictionless plane applied as a grid velocity constraint produces a nonzero, off-centre reaction whose impulse, torque and nonpositive work are balanced exactly by APIC's particle state, while PIC's missing affine state loses angular momentum by the same amount the binary64 reference predicts. Transfer loss is accounted separately from external work, and an oversized step is rejected as a whole with no committed ledger. This is a bounded external-mechanics contract on tiny fixtures, not a fluid, granular or rigid-body solver.

## What one step does

P2G from the immutable admitted particles; optional uniform gravity on occupied nodes; the plane constraint on nodes with `y<=h` and negative normal velocity (`v_y` set to zero, tangential components untouched); G2P with unchanged masses and weights; explicit `x_candidate=x_old+dt*v_new`; validation of finite state, complete kernel support and the declared half-space; then one serial commit invocation that either accepts all particles plus the step's external ledgers or none of them. Rejected steps halt later queued steps until reset, contribute no impulse, torque, work or elapsed time, and the authoritative snapshot grid is rebuilt from committed particles so it never exposes uncommitted forces.

For every occupied node the GPU records realized FP32 velocity changes, not only requested parameters: `J=m*(v_after-v_before)`, `T=(x-origin)×J`, `W=½m(|v_after|²-|v_before|²)`, alongside the requested values, for the gravity and wall stages separately. Transfer loss is recorded as `K_grid,pre-K_particles,old` and `K_particles,new-K_grid,post`.

## Fixture correction before GPU execution

The first CPU reference run showed that a flat frictionless plane on a purely translating cluster is **not** a PIC discriminator: the constraint only makes `v_y` vary along `y`, the quadratic B-spline weights are a tensor product, and each axis's first moment vanishes, so PIC's grid→particle projection had an angular residual of 4e-19. The plane fixture now gives the lower cluster a rigid rotation ω=(0,0,5) rad/s about its own centre (velocity plus affine C for APIC; velocity only for PIC). ω=5 was chosen so the oversized-step fixture still rejects on its first attempt (ω=15 made the extrapolated APIC node velocities large enough to accept one step). The irrotational case is kept in the CPU tests as a recorded limit with residual below 1e-15. [Plan correction](mechanics-experiment-plan.md), [CPU reference log](evidence-mechanics-gpu/cpu-reference.log).

## Results

Godot 4.6.3 / Metal 4.0 / Apple M5 Pro passes **12 admission/shader checks** and **59 GPU logical checks** (acceptance counts, mass bytes, batching in groups 1, 3 and [7,2,5,1,9], rejected-step immutability, cleared grid and ledgers after an invalid reset). The numerical evaluation passes **all gates on all five fixtures**. CPU: 7 mechanics reference tests and the 14 unchanged momentum tests pass. [GPU log](evidence-mechanics-gpu/gpu.log), [numerical evaluation](evidence-mechanics-gpu/evaluation.log), [complete metrics](evidence-mechanics-gpu/metrics.json), [raw results](evidence-mechanics-gpu/results.json), [admission](evidence-mechanics-gpu/admission.log).

| Measurement across sampled checkpoints | Worst observed | Declared limit |
| --- | --- | --- |
| Particle mass | Exact original FP32 bytes in every case | exact |
| Grid mass relative error | 5.28e-8 | 2e-6 |
| Position disagreement with binary64 | 1.58e-6 m (100 gravity steps); 9.6e-8 m (plane) | 5e-5 m |
| Velocity disagreement with binary64 | 1.31e-5 m/s | 3e-4 m/s |
| Affine coefficient disagreement | 5.82e-5 s⁻¹ | 5e-3 s⁻¹ |
| Discrete analytic gravity COM trajectory error | 8.97e-7 m | 5e-5 m |
| Applied gravity impulse vs requested / vs `M·g·dt·N` | 2.98e-8 / 2.38e-7 kg m/s | 1.23e-5 scaled |
| Applied gravity torque vs requested | 1.99e-9 kg m²/s | 2.36e-6 scaled |
| Linear balance residual `ΔP−ΣJ` | 7.49e-8 kg m/s | 1.23e-5 scaled |
| APIC angular balance residual `ΔL−ΣT` (gravity / plane) | 2.01e-7 / 5.27e-9 kg m²/s | 2.36e-6 / 5.05e-7 scaled |
| PIC plane angular residual, GPU vs binary64 | 3.808e-4 vs 3.808e-4, disagreement 4.6e-10 | 4.89e-7 scaled |
| Energy identity residual `ΔK−(loss_in+loss_out+W_g+W_w)` | 4.69e-7 J (gravity); 7.9e-10 J (plane APIC) | 9.07e-6 / 8.45e-7 scaled |
| Represented energy vs binary64 | 2.78e-7 J | scaled energy bound |
| Ledger impulse / torque / work vs binary64 | 2.69e-7 / 1.58e-7 / 2.14e-7 | scaled bounds |
| Constrained-node normal and tangential bytes | Exact on 93 node records; 0 violations | exact |
| Per-node wall impulse / work vs `−m·v_n·n`, `−½m·v_n²` | 6.0e-11 / 1.7e-10 | scaled bounds |
| Wall work | −1.99e-3 J (PIC), −3.89e-3 J (APIC) | ≤ 1e-9 J |

Balances use a fixed initial mass centroid as origin and include the affine rotational contribution `D=dx²/4·I`. Bounds are the plan's: linear `3e-5·(Σm|v₀|+Σ|J|)+1e-7`, angular `5e-5·(L-scale+Σ|T|)+1e-8`, energy `5e-5·(K₀+Σ|W|)+1e-9`, evaluated from the accumulated GPU ledgers.

### Plane contact

| Fixture | Wall impulse (y) | Wall torque (z) | Angular residual | Energy 0→20 steps | Transfer loss in / out |
| --- | --- | --- | --- | --- | --- |
| plane_pic | +0.02548 kg m/s | −2.31e-3 kg m²/s | 3.81e-4 (expected loss) | 6.94e-3 → 3.42e-3 J | −3.23e-4 / −9.76e-4 J |
| plane_apic | +0.02003 kg m/s | −2.80e-3 kg m²/s | 5.3e-9 | 1.281e-2 → 7.59e-3 J | −2.79e-4 / −8.72e-4 J |

Only the lower cluster's support met constrained nodes; the upper cluster's nodes were untouched by the wall stage (verified per node). Both methods lose roughly half of the represented energy over 20 steps, and the ledger attributes almost all of it to transfer/projection loss, not to the wall: wall work is −2.0e-3 J and −3.9e-3 J respectively. APIC retains 18% of its initial angular momentum after the contact, with the change fully explained by the recorded wall torque; PIC's balance fails by 3.81e-4 kg m²/s, matching binary64 to 4.6e-10, so the loss is the method's, not FP32 error.

### Gravity

Applied impulse over 100 steps equals `M·g·dt·N` to 2.4e-7 kg m/s. The centre of mass follows `X_N=X_0+N·dt·V_0+dt²·g·N(N+1)/2` to 9e-7 m. Gravity work is 0.179 J against a transfer loss of about −2e-7 J; the discrete `−½M|g|²dt²` per-step defect is part of the analytic expectation, not counted as dissipation. APIC's affine coefficients stay within 5.8e-5 s⁻¹ of binary64, so a uniform force does not seed spurious C.

### Transactional rejection

The dt=0.5 s attempt computes a nonzero wall impulse, its candidate minimum y ends 0.01404 m below the plane, and the whole step is rejected: particles equal the initial bytes, all ten ledger rows are zero, the rebuilt snapshot grid hashes to the committed particles, and further queued attempts stay halted. An initial state placed below the plane is rejected at reset with cleared grid and ledgers.

## Limits

- The rotating cluster is ±5 mm inside 100 mm cells, so its rotation is entirely sub-grid. APIC represents it through C and extrapolates it linearly to the 3×3×3 support, which is why APIC's wall reaction differs from PIC's for the same physical setup. This is a property of the transfer, not a resolved contact.
- The plane acts on grid nodes within a particle's support before the particle centre reaches `y=h`: contact has a one-cell smoothing length. Candidate half-space rejection is an admission boundary, not a time-of-impact solver. Nothing here establishes sharp contact, thin barriers, penetration recovery, restitution, friction, rolling or stacking.
- No pressure, stress, density constraint, free surface, particle-particle contact or coupling to voxel structures exists. Strong dissipation of non-affine motion remains as previously measured.
- Gather-per-node P2G and a single-invocation commit are deliberately unscalable; no throughput claim is made. FP32 error is measured only over these 20- and 100-step trajectories on this device.
- The force-free momentum fixtures were rerun on the binary64 reference through the mechanics path (`test_forcefree_method_unchanged`); the GPU force-free regression script (`forcefree.gd`) exists but was not executed under this lease.

## Decision

The external-mechanics contract holds in FP32 for the tested cases: forces and constraints reach particle state with matched impulse/torque/work accounting, and transactional commit keeps rejected work out of the authoritative state and ledgers. The next investment decision is whether to fund collision geometry and material-specific stress/pressure laws on top of APIC's affine state, informed by the measured transfer dissipation; nothing in this unit should be sold as fluid or rigid behaviour.

Reproduction, visible GPU steps serially under the shared lease:

```sh
python3 tools/feasibility/mechanics_gpu/generate_cases.py
python3 -m unittest tests.feasibility.test_mechanics_reference tests.feasibility.test_momentum_reference tests.feasibility.test_momentum_motion
godot --headless --path . --import
godot --headless --path . -s res://tests/feasibility/mechanics_gpu/admission.gd
godot --path . --always-on-top --disable-vsync -s res://tests/feasibility/mechanics_gpu/run.gd
python3 tools/feasibility/mechanics_gpu/evaluate.py
```
