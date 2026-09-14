# The missing mass/enthalpy transport contract

The current liquid solver can supply integer-conservative target amounts, but those amounts do not uniquely determine where heat should move. A small isolated reference now reproduces a real hydro column update and transports mass plus enthalpy conservatively. It also demonstrates two valid but different transport paths for the same production result. The next production prerequisite is an explicit accepted-transfer contract, not simply another temperature texture.

## Source audit

| Existing operation | Current authoritative behavior | Heat/mass contract required |
| --- | --- | --- |
| `swap_cells`, used by vertical sorting, wind, powder slump and gas spread | Swaps four packed bytes, including material and seed. [sim.glsl](../../shaders/compute/sim.glsl#L120) | Move the complete material state, including mass/species and total enthalpy, with the same permutation. A temperature attached to the grid location would be wrong. |
| `liquid_column` | Computes a stochastic stable bottom amount and overwrites both amount bytes; the sum is conserved. [sim.glsl](../../shaders/compute/sim.glsl#L213) | Freeze the already accepted integer amount result. Under an explicit no-counterflow assumption, carry the donor's specific enthalpy with the net transferred amount. Do not resample the random decision in a heat pass. |
| `spread_row` and tiny-remnant collection | Pools amounts over eligible cells, divides them in block order and moves tiny remainders to a selected fuller neighbor. [sim.glsl](../../shaders/compute/sim.glsl#L338) | Amount pooling does not specify full thermal mixing or donor routes. The 2×2 row has no unique one-dimensional parcel order. Record transfers or deliberately choose/document a mixing model. The explicit remnant donor can carry its full remaining enthalpy. |
| `profile_column` and `relax_row` | Rewrites a whole contiguous same-liquid run from its mass total/profile or relaxed mean. No face flux or donor history is retained. Hydro keeps location seeds while redistributing amount. [hydro.glsl](../../shaders/compute/hydro.glsl#L75) | A remap policy or accepted mass transfers must be defined during this operation. Seeds cannot reconstruct parcel provenance. Run-wide pressure propagation is not evidence of a unique advective path. |
| Reactions and decay | `set_element` sets any liquid output to 200 units and nonliquid output to 0, retaining seed. Film amount changes reaction probability, not stoichiometric output amount. [sim.glsl](../../shaders/compute/sim.glsl#L124), [element reactions](../../scripts/sim/elements.gd#L55) | Existing reactions are gameplay transmutations, not a closed mass/energy model. Define species yields and explicit energy reservoirs before coupling them. The reference does not invent combustion heat, latent costs, or mass for these rules. |
| Brush, erase and box/source painting | Replaces packed cells; fresh liquid gets the configured default amount, erase gets zero. ONLY_AIR skips occupied cells. [brush.glsl](../../shaders/compute/brush.glsl#L45) | Treat accepted painting as external material/enthalpy input and displaced/erased contents as explicit output. A rejected ONLY_AIR stamp contributes neither. Record source temperature/composition with the accepted command. |
| Authored archives and regional history | Archive v1 and region records contain four voxel bytes; they have no energy payload. Upload resets solver/presentation history. [world_archive.gd](../../scripts/editor/world_archive.gd#L3), [voxel_edit_gpu.gd](../../scripts/sim/voxel_edit_gpu.gd#L232), [central reset](../../scripts/sim/voxel_sim.gd#L1273) | Authored initial thermal state needs a versioned schema/default. Region undo must capture/restore all authoritative thermal fields. A runtime snapshot must also include tick/order/source accounting; authored Return is a fresh initialization, not a continuation snapshot. |

Current `Elements.density` is used for buoyancy ordering and has no declared SI mass contract; `Elements.heat` and the coarse air velocity's fourth channel drive buoyancy, not a thermodynamic joule ledger. A liquid amount of 200 is nominal full and 255 is permitted compression. A future physical table must define mass per amount unit per material. Clamping amount/200 to1 when calculating mass silently discards compressed material. Gases and solids currently have amount 0, so extending the liquid-only mapping to all elements would incorrectly give them zero mass.

## A discriminating implementation

[enthalpy_remap.py](../../tools/feasibility/enthalpy_remap.py) ports the integer part of production `profile_column`, including surplus compression, byte clipping and carry. It then remaps one immutable homogeneous-liquid run to the accepted target amounts. The run carries integer amount units and total enthalpy in joules per cell. Empty liquid slots have zero energy and no defined liquid temperature. The illustrative test scale is 1000 kg/m³ at 1 cm cell size: each amount unit is 5e-6 kg. These are synthetic coefficients, not a reinterpretation of the production material table.

Two explicit policies expose the missing decision:

- **Monotone mass-coordinate overlap:** arrange old and new cells as consecutive intervals of integer material amount along the line. Each overlap identifies donor, receiver and accepted units. Parcels keep their order along the line; material can pass through a cell whose net amount is unchanged.
- **Retain local material:** keep `min(old,new)` at each location, then match surplus donors to deficits in ascending index order. This avoids moving locally retained material but can send material past intermediate cells.

Both create an explicit `(donor, receiver, units, joules)` transfer list, including retained mass. Every donor's transfers consume exactly its old amount and old energy; incoming heat never gets reused as an outgoing donor in the same remap. The final segment receives the donor's floating-point energy remainder. Receiver sums use binary64 `fsum`. Empty outputs retain no residual energy. The output ledger checks old/new units and joules; external edits separately record mass/energy in and out. Relative enthalpy may be negative, so energy ledger entries are signed quantities relative to 273.15 K.

A real column example makes the ambiguity visible:

| Field | Initial | Production hydro target | Monotone result | Retain-local result |
| --- | --- | --- | --- | --- |
| Amounts, bottom→top | `[100,100,100]` | `[200,100,0]` | Same target | Same target |
| Liquid temperatures | `[300,400,500] K` | Not specified | `[350,500,empty] K` | `[400,400,empty] K` |
| Total enthalpy | 190.275 J | Not specified | 190.275 J | 190.275 J |

Keeping the original cell temperatures while applying the new amounts instead gives `[300,400,empty] K` and **loses 100 J**. Averaging temperature directly would also be wrong for unequal mass or latent enthalpy; mix transported total enthalpy, then decode temperature from the new mass/material.

Monotone remapping is a possible one-dimensional closure, not physics already implied by hydro. For a line, the amount difference can determine net face flow after choosing closed boundaries, but not counterflow, donor mixing, or through-flow temperature. In the full solver, alternating axes and block pooling add more choices. Either policy can carry heat across a long run in one tick because the existing pressure update is nonlocal. This experiment does not validate that propagation speed as fluid advection.

## Evidence and boundaries

**14 CPU tests** pass, including all 65,025 positive two-cell amount pairs, known long-column clipping cases, partial/compressed amounts, uniform temperatures from 250–600 K (including negative relative enthalpy), hot/cold mixing, donor/receiver budgets, explicit replace/erase ledgers, runtime restore and authored reset. In 1000 deterministic 32-cell remaps, integer mass stays 3441 units and maximum relative energy drift is **3.49e-16** (9.09e-13 J absolute). Targets for CPU accounting were fixed at 1e-12 relative energy and 1e-15 kg per-operation mass residual. [Test source](../../tests/feasibility/test_enthalpy_remap.py), [CPU log](evidence-thermal-gpu/remap-cpu.log).

A separate GPU harness dispatches the **unmodified production hydro shader** at 256³ and compares 18 columns of 1–256 cells, including all 1-unit/all 255-unit long runs. **54 checks pass:** exact amount targets, integer mass, and normalization of empty outputs to air. This grounds the port in the current implementation. It tests amount redistribution only; heat remapping remains CPU-only. [GPU harness](../../tests/feasibility/enthalpy_remap/production_columns.gd), [GPU log](evidence-thermal-gpu/remap-production-columns.log). The 12 existing CPU thermal-reference tests also pass. [Regression log](evidence-thermal-gpu/remap-thermal-regression.log).

Ordered batches of 1, 3 or [7,2,5,1,9] produce identical binary64 snapshots after 83 remaps. **Coalescing physical remaps is not equivalent:** applying `[100,100,100]→[200,100,0]→[100,100,100]` mixes the first two temperatures to 350 K; skipping the intermediate remap preserves 300/400 K. This is lost subcell information, not a numerical conservation failure. It reinforces preserving every authoritative solver operation while coalescing only derived rendering work. These tests do not assert order-independent results across different physical operation sequences.

This prototype accepts one fully liquid material per run. Partial *amounts* are supported; partially melted phase mixtures and unlike-material receivers are outside this model. No conduction, reaction energy, pressure work, species separation, physical density changes, GPU enthalpy arithmetic or transport performance is claimed. The artificial compressed amount profile is not an equation of state; adding compression heating would require a separate mechanical work/pressure contract.

Independent integration review found that a frozen `Run` still accepted a caller-owned mutable energy list. Mutating that list changed an existing runtime snapshot without updating its ledger. Admission now requires an energy tuple, matching the immutable amount contract; the regression rejects the alias before a session can retain it. All **15 CPU tests** pass after this fix. [Independent log](evidence-thermal-gpu/remap-integrated.log).

## Concrete next contract

A future material-motion operator should consume an immutable old mass/enthalpy state and return accepted transfers or an explicit permutation, plus a separate source ledger. Applying that result must update amount and enthalpy together, using the same accepted integer decisions and fixed operator order. Resolve every donor budget before mutating any receiver. For the current tick that means following the actual reactions/decay, vertical/wind/slump/spread/vertical/gas order, then the column hydro and alternating horizontal hydro passes. [Current tick schedule](../../scripts/sim/voxel_sim.gd#L1104).

The next minimal coupled experiment should isolate same-liquid motion with reactions/decay disabled, choose a documented hydro remap closure, and test its energy ledger on the GPU. It needs a versioned mass scale, an authored initial-temperature policy and atomic region-history coverage first. The measured stationary conduction candidate can then read the updated mass/energy, with a stability bound and geometry appropriate to partial/compressed cells. Its full-fixed-cell bound must not be reused blindly.

Reproduction, GPU command only while holding the shared GPU lease:

```sh
python3 -m unittest tests.feasibility.test_enthalpy_remap -v
python3 tools/feasibility/generate_remap_columns.py
godot --path . --always-on-top --disable-vsync --resolution 640x480 -s res://tests/feasibility/enthalpy_remap/production_columns.gd
python3 -m unittest tests.feasibility.test_thermal_reference
```
