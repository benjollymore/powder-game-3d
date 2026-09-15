# Thermal physics: the temperature layer

Status: implemented for the heat milestone (contracts in [heat-brief.md](heat-brief.md)); acceptance checks live in `tests/gpu/run_gpu_tests.gd` (`_test_heat_*`, `_test_ice_plateau`, `_test_water_over_lava`, `_test_wood_ignites_by_conduction`) and the CPU oracles `tests/milestone/thermal_init.gd` and `thermal_remap.gd`. GPU numbers and tuning evidence are recorded by the coordinator once the suites have run on the integration branch.

## State and energy

Every cell carries `T` (kelvin) and `G` (latent progress, joules) in an `RG32F` texture beside the packed voxel grid. Energy is `E = C·T + G`, where the capacity `C` is the element's `heat_capacity` (J/K per full cell) scaled for liquids by exactly `amount / 200`. Linearity matters: every transfer moves energy proportionally to units, so a capacity floor (tried first) made a two-unit receiver read colder than its donors and froze water at room temperature. Compressed liquid (amount above 200) holds proportionally more heat; the clamp on conduction keeps tiny cells bounded between their neighbours. `VoxelSim.energy_total` sums the same model on the CPU.

Temperature rather than enthalpy is authoritative because the four-byte cell record has no calibrated mass; the enthalpy references under `thermal-feasibility.md` established the arithmetic (half-cell resistance conductance, canonical operand order, `precise`), which `thermal_common.glslinc` ports.

## Conduction

`rule_thermal` in `sim.glsl` runs inside the Margolus block: the twelve in-block faces exchange `q = dt · dx · 2kᵢkⱼ/(kᵢ+kⱼ) · ΔT`, each clamped to half the amount that would equalise the pair, applied in sequence. That is exactly conservative per face and unconditionally stable. The partition offset rotates each tick, so heat crosses block boundaries the way sand does. `dt` is `seconds_per_tick × thermal_speed` (default 120, so one simulated thermal second per tick: centimetre-scale conduction is far too slow to watch in real time). Faces to cells outside the box, and to materials with zero conductivity, carry nothing.

Conductivities are gameplay values. **Wall is a perfect insulator**, so a box keeps its heat. Still air barely conducts (0.02); hot gases carry heat by moving. A flame conducts like a convecting gas (1.0). Metal (50) is the heat pipe. Flames are heat sources: `pin_fire` holds any element with a `fire_temp` at that temperature before and after conduction, for as long as the flame lives, and the overshoot clamp treats a flame as an unbounded reservoir rather than a 0.05 J/K gas, so energy is not conserved while fire burns (by design).

## Phase change and ignition

`settle` (in `thermal_common.glslinc`) keeps `C·T + G` fixed while moving energy between `T` and `G` at a plateau: above `hot_at` the excess goes into `G ≥ 0` and `T` stays at `hot_at`; below `cold_at` the deficit goes into `G ≤ 0`. Stored latent drains back before a cell can leave its plateau. `rule_phase` then transmutes when `|G|` reaches the transition's latent energy, which is always **the lower phase's `latent × heat_capacity`** (× fill for liquids): boiling and condensing move the same 2257 J per water cell, melting and freezing the same 168 J per ice cell, stone and lava 630 J. On transition `G` is dropped (absorbed) or created (released); this species-change energy is a declared non-conserved term for this milestone. A cell already past its plateau by more than the latent energy (painted cold lava, water dropped into a furnace) changes phase immediately at its own temperature, so it never acts as a heat source of energy it does not have.

Flammable elements at or above `ignition_temp` catch with `ignite_chance` per tick (default 0.05) and become their `burn_to`. Reactions can require a minimum temperature (`min_t`) and release `heat` kelvin into outputs that are not flames; a transmutation keeps the cell's temperature and zeroes its latent progress. Clone emission and painting are sources: new material starts at its element's `initial_temp`.

## Heat travels with material (the accepted-transfer contract)

- Swaps (`swap_cells`) permute the thermal state with the voxel.
- `liquid_column`: a whole parcel entering an empty cell exchanges thermal state with the air it displaces; a partial transfer mixes the receiver by capacity-weighted mean and leaves the donor unchanged.
- `spread_row`: the "retain local material" closure: each pooled cell keeps `min(old, new)` units at its own energy per unit and surplus donors feed deficits in block order, so heat only moves with material. Full mixing was tried first and smeared latent progress across a pool so nothing could boil. Remnants merging into a fuller neighbour carry their energy.
- `hydro.glsl` remaps each run's energy monotonically along the mass coordinate, so parcels keep their order and a hot bottom stays a hot bottom. The streaming walk keeps originals of cells the receiver cursor has rewritten before the donor cursor reaches them in a per-thread ring (24 entries, shared memory); a run that exceeds it keeps its previous temperatures for the rest of the run (bounded, documented). `tests/milestone/thermal_remap.gd` ports the walk and checks it against the segment remap of `tools/feasibility/enthalpy_remap.py`, including the top-heavy runs that make the cursor lag.
- Air displaced by liquid (a partial parcel entering an air cell, a remnant merge leaving air behind) loses or gains air's energy; air's capacity is its physical 0.001 J/K per cell, so this is negligible. The falling-water test records the measured drift.

## Buoyancy, brushes, inspection

`air_downsample.glsl` sums `max(0, T − ambient) / 400` over air and gas cells instead of a per-element constant, so plumes rise because they are hot. `brush.glsl` modes HEAT and COOL add or subtract a strength in kelvin with radial falloff `(R² − d²)/R²`, `R = radius + 1`, without touching voxel bytes (`VoxelSim.paint_thermal`, `record_thermal_stroke` for undo); painted material starts at its initial temperature and erased cells keep theirs. `request_state_readback` returns both layers from one render-thread job; the cell probe reports temperature.

## Limits

No conservation across species change; no sun heating; no bulk convection of air heat back into voxels (only gases move); painting water into a hot cell starts it cold; the hydro ring fallback and air displacement are the two documented energy leaks. Tuning constants (`thermal_speed`, `ignite_chance`, conductivities) are gameplay choices to be judged by play, with the physics tests as the floor.
