# Proposed next mechanics experiment

**Recommendation:** add one isolated grid-force/constraint stage to the validated finite-motion reference, then test uniform gravity and an off-centre frictionless plane constraint. This is small enough to audit but distinguishes preservation during transfer from correct response to external momentum exchange. No pressure, stress, deformable material, production solver, or scalable transfer implementation is proposed in this unit.

This document declares the proposed contract and gates before implementation. No mechanical-force GPU kernels or results are included yet.

## Why this test

The current reference establishes that force-free PIC/APIC transfer and advection can preserve the appropriate mass/momentum within FP32 bounds. It does not show that a force or contact reaction reaches the particle state correctly, that affine angular momentum responds to a torque, or that boundary work is separated from numerical dissipation. Merely adding gravity would be a weak discriminator: a uniform velocity increment is the easiest field for both PIC and APIC to reproduce.

An off-centre wall constraint changes grid momentum nonuniformly and creates a known reaction torque. APIC should carry that torque back into its full particle state; PIC is a useful negative control because its missing affine state can lose angular momentum during grid→particle transfer. The intended test is an explicit **grid velocity constraint**, not a claim that a diffuse interpolation stencil is an accurate thin-wall collision model.

**Corrected expectation (binary64 reference, before GPU runs):** a flat frictionless plane acting on a purely translating, irrotational cluster does *not* expose PIC's loss. The constraint only makes `v_y` depend on `y` inside the lower cluster's support; because the quadratic B-spline weights are a tensor product and each axis's first moment `sum_i w_i (x_i - x_p)` vanishes, PIC's grid→particle projection of that field has an angular residual of exactly zero (measured 4e-19). PIC loses angular momentum only when the grid field has curl within a particle's support. The plane fixture therefore gives the lower cluster a rigid rotation about its own centre, represented as velocity plus affine `C` for APIC and as velocity alone for PIC. The reference test keeps the irrotational case as a recorded limit and reports PIC's residual with and without the wall so that plain transfer loss is not misread as a wall effect.

## One step and its authoritative boundary

1. P2G from the old, admitted particles. Record grid momentum/angular momentum/represented energy before mechanics.
2. Apply optional uniform gravity to occupied grid nodes.
3. Apply the stationary frictionless plane velocity constraint to selected nodes.
4. G2P using the unchanged masses/weights, then `x_candidate = x_old + dt*v_new`.
5. Validate all candidate particles for finite state, complete kernel support, and the declared geometric half-space.
6. One commit invocation either accepts all particle state plus the step's external ledgers, or accepts none of them. Rejected work does not contribute accumulated impulse, torque, work or elapsed physical time. Subsequent queued steps halt as in the current reference.

Mechanical stages do not create/remove mass. Grid support is never clipped or renormalized. A particle outside the admissible half-space is rejected, not snapped, reflected, deleted or silently clamped.

**Important snapshot consequence:** after adding forces, the working grid of a rejected step contains uncommitted velocity changes. The current force-free shortcut of retaining the P2G grid is no longer sufficient. A snapshot must either rebuild its transfer grid from authoritative particles even after a rejected candidate, or return a separately retained last-committed grid with an explicit label. Initial-invalid reset must still clear all grid and ledger buffers. Tests must distinguish working-grid diagnostics from authoritative snapshots.

## Impulse, torque and work ledger

For every occupied node, record actual FP32 velocity changes, not only requested force parameters. For each stage:

```text
J_i = m_i * (v_after - v_before)
T_i = (x_i - fixed_origin) cross J_i
W_i = 0.5 * m_i * (|v_after|^2 - |v_before|^2)
```

The requested impulse has its own comparison against the applied impulse, so using realized deltas cannot hide a force-dispatch error. Zero-mass nodes receive no force and contribute nothing. For testing, keep per-node records and perform deterministic reductions; no float atomics are needed at this tiny scale.

For uniform gravity, request `v_after = v_before + g*dt`, so the target total impulse is `M*g*dt`. The target torque is `sum((x_i-origin) cross (m_i*g*dt))`. The uniform translating-cloud control has the known discrete trajectory:

```text
V_N = V_0 + N*dt*g
X_N = X_0 + N*dt*V_0 + dt^2*g*N*(N+1)/2
```

This is the existing velocity-first explicit position update (symplectic Euler for this force), not the exact continuous parabola. With no transfers/contact error, its kinetic-plus-gravitational-potential energy changes by `-0.5*M*|g|^2*dt^2` per step. Report that discrete integration defect separately; do not fail a correct implementation for lacking exact continuous energy conservation, and do not call the defect physical dissipation.

For a stationary plane at `y=h`, normal `n=(0,1,0)`, apply only when an occupied node has `y<=h` and `v_n<0`:

```text
v_after = v_before - v_n*n             # restitution e=0, no friction
J_wall = -m*v_n*n
W_wall = -0.5*m*v_n^2 <= 0
```

Tangential grid velocity is unchanged. Accumulate equal/opposite impulse and torque for the prescribed wall reservoir. No wall velocity, rigid-body response or friction coefficient is invented. The contact lever arm can be projected onto the plane without changing torque because the impulse is normal to it.

For APIC, the accepted particle balances should satisfy:

```text
P_new - P_old = J_gravity + J_wall
L_new - L_old = T_gravity + T_wall     # orbital plus affine angular momentum
Kp_new - Kp_old = (Kg_pre - Kp_old) + W_gravity + W_wall + (Kp_new - Kg_post)
```

The two parenthesized terms measure transfer/projection energy loss separately from external work. Explicit advection along `v_new` changes no orbital angular momentum at that substep (`v_new cross v_new=0`). PIC's angular residual after G2P is measured as its expected limitation, not assigned to the wall reservoir to make a false balance.

## Bounded fixtures

| Fixture | Setup | Discriminating observation |
| --- | --- | --- |
| Uniform gravity, PIC and APIC | 27 unequal-mass particles, 10³ grid, dx=0.1 m; uniform initial velocity; g=(0,-9.81,0) m/s²; dt=0.001 s for 100 steps, positions with ample interior/plane clearance | Correct requested/applied impulse; discrete analytic COM trajectory; no spurious C growth beyond FP32 tolerance; integration energy defect separately reported |
| Off-centre stationary plane, PIC and APIC | Two small unequal-mass clusters at different x/y, e.g. lower-left y≈0.23 m and upper-right y≈0.43 m; plane y=0.2 m; initial velocity=(0.1,-0.25,0) m/s plus a rigid rotation ω=(0,0,5) rad/s of the lower cluster about its centre (APIC also carries the matching affine C; PIC carries only the resulting particle velocities); gravity off; dt=0.002 s for 20 steps | Only the lower cluster's interpolation support meets the constrained nodes; nonzero upward reaction and off-centre torque. APIC balances total angular momentum including C; PIC's residual (about 1.4e-5 kg m²/s on the first step, versus 1e-18 for APIC) remains visible. An irrotational variant is kept as a control showing zero PIC residual. Wall work is nonpositive and tangential grid velocity unchanged |
| Transactional rejection | Same rotating plane fixture with an intentionally oversized step (dt=0.5 s) whose first post-constraint candidate crosses y=0.2 while remaining inside the outer grid | Whole step rejected; particles, accumulated ledgers and accepted time unchanged; snapshot contains no uncommitted forced grid. Repeat across queued batches and valid→invalid reset |
| Force-free regression | Existing eight fixtures | Original mass/momentum/trajectory gates and exact batching remain unchanged |

The plane acts on grid nodes within a particle's interpolation support before its centre reaches the geometric plane. That smoothing length is deliberate and must be shown in the result; this test cannot establish sharp contact, thin barriers, penetration recovery, restitution, rolling friction or stacking. Candidate half-space rejection is an admission boundary, not a time-of-impact solver. No fixture should be moved after execution merely to avoid exposing that limit.

## Proposed acceptance gates

Use the existing FP32/binary64 comparison and trajectory limits: 5e-5 m maximum position, 3e-4 m/s velocity and 5e-3 s⁻¹ affine coefficient errors. Particle mass bytes remain exact; grid mass relative error ≤2e-6. Keep the current no-force tolerances unchanged.

For forced runs, bound accumulated **balance residuals**, not momentum changes themselves:

- Linear residual norm ≤ `3e-5*(sum(m*|v_initial|) + sum(|J_applied|)) + 1e-7 kg m/s`.
- APIC angular residual norm ≤ `5e-5*(initial angular scale + sum(|T_applied|)) + 1e-8 kg m²/s`.
- Applied-vs-requested gravity impulse uses the same linear bound. Plane impulse must be nonzero in the contact fixture; a missing force dispatch cannot pass with all-zero ledgers.
- Independently check each constrained node against the declared wall formula: normal velocity becomes zero, tangential velocity bytes are unchanged, impulse agrees with `-m*v_n*n`, and work agrees with `-0.5*m*v_n^2` within the scaled ledger bounds. Unselected nodes must remain unchanged by the wall stage. The energy identity alone is a bookkeeping check and cannot prove that the constraint was implemented correctly.
- Total work/energy identity residual ≤ `5e-5*(K_initial + sum(|W_external|)) + 1e-9 J`; stationary-plane work must be nonpositive up to 1e-9 J. Compare represented energy with binary64 and display transfer loss independently.
- Discrete analytic gravity COM trajectory uses the 5e-5 m position limit. Contact trajectories compare with the same declared binary64 grid-constraint method, not a rigid collision trajectory.
- Accepted schedules in batches 1, 3 and irregular groups must match particle and ledger bytes. Rejected steps must leave all authoritative bytes unchanged, except the explicit rejection status.

If APIC fails these external balance gates, investigate the force location, affine accounting and commit semantics before considering pressure or constitutive models. If it passes, the result establishes a bounded external-mechanics contract, not a liquid/solid solver. The next decision would be whether to invest in collision geometry and material-specific stress/pressure laws, informed by the already observed strong dissipation of non-affine motion.
