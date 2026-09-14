# Thermal feasibility reference

The isolated reference demonstrates conservative stationary conduction, a melting enthalpy curve, and explicit energy accounting when liquid mass transfers. It does **not** implement coupled moving material, chemical reactions, boiling, or a production thermal solver. No game code, renderer, physical voxel state, dependencies, or GPU resources changed.

Run with Python's standard library:

```sh
python3 -m unittest discover -s tests/feasibility -v
```

Implementation: [`thermal_reference.py`](../../tools/feasibility/thermal_reference.py). Deterministic experiments: [`test_thermal_reference.py`](../../tests/feasibility/test_thermal_reference.py). Validated with Python 3.9.6, binary64 arithmetic, on the existing M5 Pro host. All 12 tests pass. Runtime is roughly 0.03 seconds for these tiny fixtures; this is not a game performance estimate or evidence about GPU FP32 accuracy.

## State and units

Each parcel has material coefficients, mass `m` in kg, and total enthalpy `E` in J. Temperature is a derived quantity from specific enthalpy `h = E/m`, never the conserved state itself. Empty parcels have exactly zero mass and energy and no temperature. All temperatures are kelvin; lengths are metres, time seconds, conductivity W/(m·K), heat capacity J/(kg·K), density kg/m³, and latent heat J/kg.

Coefficients are **synthetic**, not calibrated water/wood/sand properties. The two solid fixtures use `(density, conductivity, heat capacity)` of `(1000, 10, 1000)` and `(2000, 20, 2000)`. The phase-change fixture has density 1000, conductivity 10, solid/liquid capacities 1000/2000, melting temperature 300 K, and latent heat 100,000 J/kg. Density and conductivity are constant across phase change. The model assumes a constant-pressure thermal accounting approximation, with no expansion, pressure work, or chemical formation energy.

The enthalpy datum is solid material at 273.15 K. With melting temperature `Tm`, solid capacity `cs`, liquid capacity `cl`, and latent heat `L`:

```text
hs = cs (Tm - 273.15)
h < hs:       T = Tm + (h - hs)/cs,       liquid fraction = 0
hs ≤ h ≤ hs+L: T = Tm,                    liquid fraction = (h - hs)/L
h > hs+L:     T = Tm + (h - hs - L)/cl,   liquid fraction = 1
```

The zero-latent-heat case skips the plateau. Adding energy through the plateau changes phase fraction instead of temperature. This is a small explicit enthalpy model; it does not reproduce the iterative algorithms or broad phase-change capabilities discussed in [Swaminathan and Voller, On the enthalpy method](https://experts.umn.edu/en/publications/on-the-enthalpy-method/).

## Conduction and stability contract

`Grid` contains full stationary cubic cells with equal side `dx`, insulated exterior faces, and fixed material assignments. For each internal face, two half-cell resistances give conductance

```text
Gij = area / (dx/(2ki) + dx/(2kj)) = dx · 2ki kj/(ki+kj)  [W/K]
Qij = dt · Gij · (Tj - Ti)                              [J]
Ei_new = Ei_old + Qij
Ej_new = Ej_old - Qij
```

A zero conductivity blocks exchange. Every face is visited once, old temperatures supply all fluxes, and energy deltas apply simultaneously. Equal/opposite face transfers conserve global energy up to floating-point accumulation. `add_energy()` separately records externally supplied or removed joules; a closed conduction step does not alter that ledger.

The timestep guard is

```text
dt ≤ min_i [mi · min(cs_i, cl_i) / Σj Gij]
```

The inverse enthalpy curve has slope at most `1/[m·min(cs,cl)]`; its slope on the plateau is zero. This conservative bound therefore limits a cell's temperature change to its available neighbour temperature differences. In the uniform 1D case it reduces to `dx²/(2α)`, with `α = k/(ρc)`, matching the explicit diffusion restriction in [NIST FiPy's diffusion example](https://www.ctcms.nist.gov/~wd15/fipy/examples/diffusion/generated/examples.diffusion.mesh1D.html). The multidimensional fixture uses the sum over all six faces. This derivation and the tests cover these constant coefficients; they do not validate nonlinear conductivity or a compressible mixture.

`advance(count, dt)` repeats identical steps. It never replaces several ticks with one larger step. Callers must schedule sources or transfers at the same absolute simulation ticks if they expect combined event histories to be batching invariant.

## Measured reference results

| Experiment | Result | Test gate |
|---|---|---|
| Insulated 8×4×4 two-material blocks, 300/400 K, 10 seconds | Relative total-energy drift 1.21×10⁻¹⁶; all temperatures stay in [300,400] K; eight 1.25 s steps | Drift <10⁻¹²; no overshoot beyond 10⁻¹⁰ K |
| Two cells with heat capacities 1 and 4 J/K | Equilibrate to 320 K | Match capacity-weighted equilibrium to 10 decimal places |
| 3³ hot-centre cell | Six face neighbours warm equally; corners unchanged | Match one-step analytic exchange to 10 decimal places |
| Insulated 1D cosine diffusion, 0.1 m slab, one second | RMS temperature error at 16/32/64 cells: 0.00161038 / 0.000506480 / 0.000126599 K | Each refinement improves >3×; finest error <0.001 K |
| Finest diffusion refinement | Error ratio 4.00066 | Tests spatial/time refinement together with `dt ∝ dx²` |
| Heating a 1 g parcel, 290→310 K | 10 J sensible solid +100 J latent +20 J sensible liquid; melting held at 300 K | Exact expected ledger within floating-point test tolerance; reverse removal returns to 290 K |
| Two-cell conduction across melting | Eight intermediate plateau observations; relative energy drift 2.16×10⁻¹⁶ | Nonzero plateau samples, no overshoot, drift <10⁻¹² |
| 80 identical conduction ticks, individual vs batches 3/7/1/20/49 | Mass/energy/tick/source snapshots exactly equal | Binary64 equality |
| Zero-conductivity neighbour | No exchange over ten 100 s steps | Energy values exactly unchanged |

The cosine initial condition uses cell averages of `350 +20 cos(πx/length)`. The analytic solution multiplies that mode by `exp[-α(π/length)²t]`. The first refinement ratio is 3.18 rather than exactly four because each resolution rounds its stable step count upward to end at exactly one second. The finest ratio is approximately four. Conservation alone would not establish this agreement with the diffusion equation.

One initial test failed because it compared the calculated equilibrium `320.00000000000006` to `320` with exact equality. The physical equilibrium checks already used a tolerance; the redundant expected-value assertion was corrected to the same ten-decimal tolerance. No model parameter or acceptance target changed to obtain passing physical results.

## Liquid transfer is an accounting contract, not a flow simulation

`transfer_liquid(donor, receiver, accepted_mass)` requires the **accepted** mass after a future transport solver has resolved availability, receiver capacity, and boundary motion. It transfers `Q = accepted_mass × donor_specific_enthalpy` and that same mass in one operation. The donor loses both, the receiver gains both; the receiver derives its new temperature from total energy divided by total mass. It supports the same material on both sides, including an empty receiver, and requires a fully liquid donor. Failed validation leaves both parcels unchanged.

The test moves 0.25 kg from a 2 kg, 330 K liquid parcel into a 0.5 kg, 310 K parcel. The donor remains 330 K; the receiver becomes 316.6667 K. Moving the remainder empties the donor to `(mass, energy) = (0,0)` and produces 2.5 kg at 326 K. Both mass and total energy are conserved.

Two negative controls matter:

- An unguarded two-cell explicit step at twice the permitted timestep would drive a 300 K cell to 500 K despite its hottest neighbour being 400 K. The public step rejects it before mutation.
- Moving mass while leaving each parcel's energy in place can preserve **global** energy while producing incorrect specific enthalpies and temperatures. The donor-temperature check catches this error, so a global conservation assertion alone cannot pass the transport contract.

Mixed-material transfer and partially melted donors are explicitly rejected. Selectively extracting liquid from a melting mixture needs its liquid-phase enthalpy and phase mass, not simply the donor's bulk average. There is no free-surface geometry, accepted-volume computation, momentum advection, partial-cell contact area, or liquid-movement rule here. After a parcel transfer changes cell fill, grid conduction refuses to continue; silently reusing a full-cell contact face would claim geometry that the reference does not know. Changing a material also requires rebuilding its conduction faces.

For production coupling, voxel swaps must move the corresponding energy state, hydro amount transfers must carry enthalpy with accepted mass, and reactions must specify product mass and chemical/source energy explicitly. The existing integer amount byte first needs a material mass calibration. A FIRE ID should not inject an unlimited temperature merely by persisting. Build→Run snapshots and undo/edit semantics must specify the initialized or restored energy too. None of these integration changes are implemented by this reference.

The next useful experiment is a small FP32 shader counterpart with the same face-energy and phase-curve fixtures, followed by one actual accepted liquid-amount transfer from the game solver. A stationary diffusion demo alone does not answer whether phase-selective moving material, reactions, numerical substeps, or dense field costs meet the game's requirements.
