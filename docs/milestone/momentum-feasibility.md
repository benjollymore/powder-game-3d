# Particle/grid momentum transfer reference

The isolated comparison supports storing an affine velocity matrix alongside particle velocity if a future material solver uses APIC. The extra state preserves rotational and general affine motion that PIC transfers dissipate in these fixtures. It does **not** establish a fluid or MPM solver, full kinetic-energy conservation, stable moving particles, or real-time feasibility.

Implementation: [`momentum_reference.py`](../../tools/feasibility/momentum_reference.py). Experiments: [`test_momentum_reference.py`](../../tests/feasibility/test_momentum_reference.py). No production files, dependencies, GPU resources, or simulation rules changed.

```sh
python3 -m unittest discover -s tests/feasibility -p 'test_momentum_reference.py' -v
```

All ten momentum tests pass with Python 3.9.6, binary64 arithmetic. They take approximately 0.6 seconds on the M5 Pro host. The combined thermal/momentum suite has 22 passing tests. Neither runtime is a GPU or production performance estimate.

## Exactly what the comparison does

Twenty repeated particle→grid→particle transfers at **fixed particle positions**, with zero elapsed physical time. There are no forces, pressure projection, stress, deformation gradient, advection, collisions, viscosity, reseeding, or boundary conditions. An eight-node-per-axis grid uses 0.1 m spacing. The main fixture has 27 particles at all combinations of 0.23, 0.315, and 0.41 m; masses vary from 0.010 to 0.018 kg, totalling 0.372 kg. Each particle has its full quadratic 3×3×3 support strictly inside the domain. No support is clipped or renormalized.

PIC and APIC use the same support weights, masses, positions, and initial particle-centre velocities. APIC additionally receives the known affine velocity matrix for affine fixtures. This is essential: matching centre velocities alone does not make the two methods' complete states or initial represented energies equal. A separate negative control initializes APIC's matrix to zero and shows that it then fails to reproduce the prescribed rotation on the first transfer, while preserving its correctly accounted total angular momentum.

The method choice follows the primary APIC paper, which augments constant particle velocities with local affine information to reduce transfer dissipation. The authors' technical report explicitly proves affine-field reproduction for zero-time transfer and conservation properties; this reference tests that restricted setting rather than claiming their full dynamics scheme. [Jiang et al., The Affine Particle-In-Cell Method](https://www.disneyanimation.com/publications/the-affine-particle-in-cell-method/), [technical report, sections 3 and 5](https://media.disneyanimation.com/uploads/production/publication_asset/105/asset/apic-tec.pdf).

## Transfer and measurement contract

Particle state is position `x` [m], mass `m` [kg], centre velocity `v` [m/s], and matrix `C` [1/s]. The local velocity at grid offset `r = xi-xp` is `vp + Cp r`. For these quadratic weights, the covariance is `D = Σi wip r rᵀ = dx²/4 I`. Tests independently check partition of unity, zero first moment, and all covariance entries at several subcell positions.

```text
Particle → grid:
  mi      = Σp wip mp
  mi vi   = Σp wip mp (vp + Cp (xi-xp))

Grid → particle, positions unchanged:
  vp_new  = Σi wip vi
  Cp_new  = (4/dx²) Σi wip vi (xi-xp)ᵀ
```

PIC omits `C` on both transfers. Its inputs must explicitly carry zero matrices; the reference rejects accidentally feeding an APIC state into PIC. Grid-to-particle transfer assumes grid masses/support still match the preceding particle-to-grid distribution. Tests prescribing new grid velocities preserve those masses. Nodes with missing or nonpositive support mass reject.

The quadratic-kernel `C` form corresponds to the paper's `B D⁻¹` form; a different interpolation kernel or moving-position integrator requires revisiting the identities. The later APIC analysis discusses why interpolation choice matters and why multilinear interpolation is not an interchangeable substitute for this formulation. [Jiang, Schroeder and Teran, An angular momentum conserving Affine-Particle-In-Cell method, sections 5–6](https://arxiv.org/html/1603.06188).

Linear momentum is `Σp mp vp`. Angular momentum must include both orbital and affine contributions. About the declared origin `o`, this reference evaluates

```text
L = Σp mp [(xp-o) × vp + d (C32-C23, C13-C31, C21-C12)]
d = dx²/4                 # matrix subscripts here are 1-based
```

The affine term equals `Σp,i mp wip r × (Cp r)`. Omitting it can report apparent angular-momentum loss even when the transfer preserved its full state. The single-particle spin fixture has zero centre velocity and zero orbital angular momentum, but nonzero affine angular momentum; transferring it to the grid and back preserves that spin. Dropping its matrix erases the spin entirely.

For energy, we report centre energy separately from the local affine contribution:

```text
Kcentre = ½ Σp mp |vp|²
Kaffine = ½ Σp mp d ||Cp||²_F
Ktotal  = Kcentre + Kaffine
Kgrid   = ½ Σi mi |vi|²
```

`Ktotal` is the weighted energy of the local velocity representations, `½Σp,i mp wip |vp+Cp r|²`; it is not an assertion that all overlapping local states correspond to a unique continuum velocity. Averaging incompatible contributions at a grid node can dissipate energy. The tests therefore check nonincrease through both transfers for the non-affine fixture, rather than demanding energy conservation where this representation does not provide it.

## Measured results and negative controls

| Fixture | Result after 20 round trips | Acceptance gate |
|---|---|---|
| Constant translation, PIC and APIC | Centre velocities and linear momentum preserved | Vector errors ≤10⁻¹² in SI units |
| Full affine field, APIC | Maximum centre-velocity error 2.75×10⁻¹⁵ m/s; maximum matrix-entry error 1.93×10⁻¹⁴ s⁻¹ | Both <10⁻¹²; grid also reproduces the prescribed field |
| Rotating cloud, APIC | Angular retention 1.000000000000003; centre-energy retention 1.000000000000006 | Retention equals one to 11 decimal places |
| Same rotating centre velocities, PIC | Angular retention 0.00135525; centre-energy retention 0.00000203564 | Negative control: both <0.1 while mass and linear momentum remain conserved |
| Non-affine velocities and matrices, APIC | Energy retention 0.086257982; linear error 1.83×10⁻¹⁶ kg·m/s; angular error 5.17×10⁻¹⁷ kg·m²/s | Mass/momentum conserved within 10⁻¹²; each transfer's energy nonincreasing within 10⁻¹² J |
| Arbitrary prescribed grid velocities, APIC | Grid-to-particle mass/linear/angular accounting passes | Same conservation tolerance; grid masses preserved |
| Single particle with affine spin | Orbital term is zero; affine spin survives transfer | Full angular/energy checks pass; erased-matrix control loses spin |
| Identical transfers grouped 3/5/12 vs individually | Particle records exactly equal; positions unchanged | Binary64 equality |

The rotating fixture uses angular velocity `(1,2,3)` s⁻¹ about its centre of mass. Both methods start with centre energy **0.027657932 J**. APIC also starts with **0.013020000 J** of affine energy, while PIC starts with zero. Ratios normalize each method to its own initial state; the result should not be read as a comparison at equal initial total energy. Both particle-to-grid transfers conserve their initial angular momentum; PIC loses rotation when grid velocities are interpolated back without retaining the affine state.

The non-affine fixture intentionally varies velocities by sine/cosine of particle index and gives particles incompatible local matrices. APIC loses approximately **91.4%** of represented energy across 20 transfers while preserving mass and momentum. That is an important limit: the rotation result does not make APIC generally nondissipative. There is no physical viscosity here to which that transfer loss could be attributed.

Boundary support is rejected explicitly. The reference does not show mass/torque conservation near walls, thin barriers, moving bodies, free-surface reseeding, or domain exit. No tolerance or input fixture was changed to obtain a passing result; the first ten-test run passed.

## Implication for a future material solver

The current game's voxel amount, motion flags, and render-instance transforms cannot represent this momentum contract. A candidate APIC material would need authoritative mass, position, velocity, and affine state. Three position floats, three velocity floats, one mass float, and nine matrix floats are **64 scalar-packed FP32 bytes before alignment or extra fields**. That happens to equal the current render-instance byte count but is entirely different data; GPU layout, material IDs, thermal energy, sorting, temporary grids, and any MPM deformation/plasticity state add further storage.

Initialization is part of the physical contract. An authored translating parcel can start with `C=0`; a prescribed rotational/affine velocity field must initialize its matching matrix if its full motion is to survive these transfers. Paint/erase, split/merge, save/restore, and conversion between voxel and particle regions must state how they change all momentum components and energy. Applying an impulse only to an arbitrary visual sprite would not modify the conserved material state.

This experiment answers one limited architecture question: retaining an affine velocity description can prevent a specific loss of motion introduced by transfer. It does not choose liquid pressure treatment, granular constitutive laws, rigid coupling, thermal advection, or a production particle count. The next discriminating test is the same transfer contract under FP32 and actual particle motion with a declared boundary model, before adding pressure/stress. A convincing liquid candidate still needs the dam/slosh/resting-surface and mass-leak tests in [the architecture brief](architecture-feasibility.md).
