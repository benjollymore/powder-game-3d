# Roadmap: from fundamentals to a playable sandbox toy

## Context

The fundamentals milestone (now on `main` at `a18caec`) made the editor dependable: exact painting, undo/redo, save/open, run/return, readable sand and water, deterministic tick cadence, and 16 CPU + 39 GPU regression suites. What it is not yet is a *game*. Ben's direction: first playable version is a **sandbox toy like The Powder Toy** (no goals), the priority is **physics richness**, it runs **only on this Mac**, and the plan covers **three milestones** with the first in detail.

The biggest gap versus Powder Toy is state: each cell is 4 bytes (element, seed, amount, flags) with no temperature, so fire is a decaying gas and "boiling" is one pair rule. Ten elements, five reactions. The isolated thermal references under `docs/milestone/thermal-*.md`, `enthalpy-transport.md` and `tools/feasibility/thermal_gpu/` already established conservative FP32 conduction and the missing accepted-transfer contract; nothing of that is in production.

Two corrections to the older discovery notes, verified in code: tick-batch divergence with air is **fixed** (`d463c6e`, `tests/milestone/batch_cadence.gd`), and `Texture3DRD` only rejects integer formats, so a float 3D texture (`R32G32_SFLOAT`, maps to `Image.FORMAT_RGF`) can be bound to the raymarcher and pick shader like the RGBA8 grid (verify on day 1).

## Milestone 1: "Heat and reactions sandbox" (detailed)

**Player promise:** pick anything from a categorised palette, paint it into a running world, and get a legible hot/cold-driven reaction within seconds.

### Engine: the temperature layer

- **State.** One new authoritative 3D texture `thermal`, `R32G32_SFLOAT`, grid extent: R = temperature (K, FP32), G = latent progress through a melt/boil plateau. 16 MiB at 128, 128 MiB at 256. Created in `_rt_init` next to `_grid_rid` in `scripts/sim/voxel_sim.gd`; second `Texture3DRD` for renderer/inspector. Temperature (not enthalpy) is authoritative because the 4-byte record has no calibrated mass; energy `E = C*T + G` is conserved by construction with per-element heat capacity `C` per full cell (liquids scale by `amount/200`, no clamp). Fallback if 256 memory is over budget: `R32F` plus latent progress in `grid.A` bits 3-7.
- **Conduction inside the Margolus kernel** (`shaders/compute/sim.glsl`), not a separate pass: the thread already owns 8 cells, loads `ct[8]`, exchanges heat across the 12 in-block faces with `q = dt * 2kikj/(ki+kj) * (Tj - Ti)`, clamped to half the equilibrating amount. Partition offset rotates per tick so heat crosses block boundaries like sand does. Port `canonical_transfer` from `tools/feasibility/thermal_gpu/fused_common.glslinc` into a new `shaders/compute/thermal_common.glslinc`.
- **Accepted-transfer contract** (the point of `enthalpy-transport.md`): `swap_cells` permutes `ct[]` with `c[]`; `liquid_column` and remnant merges mix by capacity-weighted mean; `spread_row` pooling fully mixes (documented closure); `hydro.glsl` `profile_column`/`relax_row` use the monotone mass-coordinate remap with `tools/feasibility/enthalpy_remap.py` as CPU oracle; brush/emitter stamps set `initial_temp[element]`; `set_element` on transmute keeps T, zeroes G.
- **Tick order** in `_rt_tick`: emitter stamp -> air step (`air_downsample.glsl` sums `max(0, T - T_ambient)` of air/gas cells into `src.w`, replacing constant `elems.heat`) -> sim kernel `rule_thermal` -> `rule_phase` -> `rule_reactions` (temperature gate + heat release) -> decay/vertical/wind/slump/spread/gas -> hydro.
- **Data-driven thermal elements.** `scripts/sim/elements.gd` `Elem` grows 32 -> 64 bytes: `heat_capacity, conductivity, initial_temp, fire_temp, ignition_temp, hot_at, cold_at, latent`, plus packed `hot_to | cold_to<<8 | burn_to<<16`. Each element has at most one hotter and one colder transition (covers ICE<->WATER<->STEAM, STONE<->LAVA, WAX pair). `FLAG_FLAMMABLE` elements ignite at `ignition_temp`; new fire is pinned to `fire_temp` while it lives. `REACTIONS` rows gain optional `{min_t, heat}` in the spare uints of `reaction_bytes()`. Replace the six copy-pasted `struct Elem` declarations (sim, fields, hydro, occupancy, splat_emit, air_downsample) with one `shaders/compute/elem.glslinc`, plus a unit check that `ELEM_BYTES` matches a shader-side sentinel. `PALETTE_SIZE` 16 -> 32 across `voxel_dda.gdshaderinc`, `voxel_volume`, `voxel_opaque`, `splat`, `leaf`, `droplet` (land first, alone, with byte-identical captures).
- **Persistence.** `world_archive.gd` VERSION 2, schema `material-seed-amount-flags-rgba8+temperature-latent-rg32f-v2`, header `layers: [{name, format, size, sha256}]`, both layers concatenated then zstd; v1 files load with `initial_temp`. `region_copy.glsl` binds both textures (12 B/cell); `voxel_edit_gpu.gd` transaction limits scale; `_rt_reset_world_history`/`_rt_run_ops` initialise thermal; `batch_cadence.gd` compares thermal bytes. Minimum "one owner" fold-in: one list of authoritative textures used by upload, reset, readback, region history and the cadence test. The full ordered-edit/state-generation owner stays in M2.

### Elements (two tranches, both in M1)

Tranche A, with the engine (thermal worker): **ICE** (immovable, melts at 273 K, latent), **LAVA** (liquid, ~1500 K, emissive, solidifies to STONE), **STONE** (immovable, melts to LAVA), **METAL** (immovable, high conductivity: the heat pipe). Existing elements gain `ignition_temp` (OIL, WOOD, PLANT), STEAM condenses when cold, WATER freezes when cold.

Tranche B, table-only (elements worker, each gated by its own physics test): **WAX / MOLTEN WAX** (low melt pair), **GUNPOWDER** (ignites at low T, large heat burst -> air whoosh, no wall damage), **GAS** (flammable rising gas, flash), **ACID** (pair rules vs SAND/STONE/PLANT/WOOD/METAL/ICE/WAX -> thinner ACID + SMOKE), **CLONE** (emits the first non-air neighbour id stored in its seed byte), **VOID** (deletes adjacent non-wall). **GLASS** (sand above melt T) is stretch. Note `rule_reactions()` breaks after the first matching rule per pair even if the roll fails, so document rule order in `REACTIONS`.

### Editor and UI (editor worker; `scripts/discovery/interaction_lab.gd`, new `scripts/editor/palette_panel.gd`)

- Palette grouped by a new `category` key; a `tip` key drives tooltips ("Lava: cools into stone, boils water, sets things alight"). Rows: Common (Sand Water Wall), Heat (Fire Lava Ice Heat Cool), then category tabs replacing "More materials". Keys 1-9 map to the first row.
- **Heat / Cool brushes** beside Erase: `BrushMode.HEAT/COOL` in `brush.glsl`, +-dT within the sphere, grid bytes untouched.
- **Hover inspector**: extend the 64-byte pick record (bytes 52..63 free, `EditGPU.decode_pick` in `scripts/sim/voxel_edit_gpu.gd:78`) with temperature and amount; status line shows "Lava · 1180 °C · full". One probe per frame, reusing the async surface pick.
- **Time scale** slider (1/8..4) bound to the existing `TimeController.time_scale`.
- **Examples** OptionButton loading any scenario as a new authored build through the document guard (the editor currently forces `current_scenario = "Empty"`).
- **Keep result as build**: one full readback on user action becomes a single undoable authored revision (from `docs/discovery/editor-references.md`). Return keeps its meaning.
- Ambient temperature in "Tools & view options" only.

### Rendering (rendering worker)

Palette 32; emission scaled by temperature above ~800 K in `voxel_opaque.gdshader`/`voxel_volume.gdshader` so lava, hot stone and metal glow and fade; ICE/GLASS as new `MaterialLibrary` layers; every new element gets a readable default look with no bespoke shader. Heat shimmer out of scope. Map new materials to existing soundscape categories.

### Scenarios (`scripts/scenarios/scenarios.gd`, CPU replay stays the oracle)

Volcano (lava over stone, water pool), Ice cave (ice, embers, meltwater bowl boils), Boiler (stone box, water, fire below, vent), Candle (wax pillar + flame), Powder keg (gunpowder trail, keg, oil pool), Acid rain (CLONE of acid over a layered pile, VOID floor), Foundry (metal bar through a wall from lava to ice). Keep the eight existing.

### Swarm organisation

Coordinator + four workers in worktrees, cherry-pick integration, single GPU lease, exactly as `docs/milestone/brief.md`. Reviewer role rotates to whichever worker is idle.

| Worker | Owns |
|---|---|
| thermal | thermal texture, `sim.glsl` rules, hydro remap, air buoyancy, brush HEAT/COOL kernel, tranche A elements, cadence/energy tests |
| elements | `elements.gd` v2 schema, `elem.glslinc`, tranche B rules, scenarios, CPU oracle, `run_gpu_tests.gd` additions |
| editor | palette/categories/tips, inspector, brushes UI, time slider, Examples, Keep, archive v2, guard integration |
| rendering | palette 32, temperature glow, ICE/GLASS layers, matched captures |

Contracts agreed on day 1 before workers start: (1) `Elements.TABLE` v2 keys and `ELEM_BYTES` 64; (2) thermal texture format, `VoxelSim.thermal_texture_rid()`, ambient constant, and the rule that thermal is authoritative state (undo, Return, Keep, archive, scenario load all include it); (3) `VoxelSim.request_cell_probe(ray, cb)` -> `{pos, element, temperature, amount, flags}`; (4) `BrushMode.HEAT/COOL` with strength; (5) one rule per unordered pair, order documented.

### Order of work

1. Palette 32 + `elem.glslinc` + 64-byte `Elem` (mechanical, byte-identical captures) — rendering + elements, first.
2. Thermal texture, bindings, init/reset/upload/readback, authoritative-texture list — thermal.
3. `rule_thermal`, `rule_phase`, temperature-gated reactions, swap/transfer contract, hydro remap, air buoyancy — thermal.
4. Brush HEAT/COOL, region copy, pick record — thermal + editor.
5. Tranche A elements + scenarios + archive v2 — thermal, elements, editor.
6. Palette UI, inspector, time slider, Examples, Keep — editor.
7. Tranche B elements, one test each — elements.
8. Glow + material layers — rendering.
9. Bench on mains, soak, docs (`docs/voxel-format.md`, new `docs/milestone/heat.md`).

### Acceptance

- **Feels like a game:** Ben plays 10 minutes unguided at 128 using tooltips alone; seven chain reactions reproducible by hand and from Examples (lava into water crusts and steams; spark -> gunpowder trail -> keg -> oil; ice over fire melts, boils, condenses on cold ice; acid eats a layered pile; CLONE fountain drained by VOID; candle melts and re-sets; metal bar melts ice through a wall).
- **Physics (extend `tests/gpu/run_gpu_tests.gd`):** closed stone box with mixed 500/300 K material, 1000 ticks, relative energy drift < 1e-5 and T within initial bounds, equilibrium within 0.5 K of `thermal_reference.py`; two-cell exchange matches `canonical_transfer` to 1e-4 K; falling water into a warm pool conserves energy through swaps, columns, spread and hydro; ice at 260 K in 300 K air holds 273.15 K while G grows then becomes water; water over lava boils and crusts; wood 5 cells from fire ignites, same with a 400 K brush blob does not; heat then cool brush returns bytes exactly; batch schedules [1], [3], [7,2,5,1,9] give byte-equal voxel, thermal and air textures; one `_test_*` per tranche B element.
- **Editor/persistence (new GPU suites in `tools/milestone/verify.py`):** `archives-thermal128` v2 round trip exact and v1 loads with defaults; regional undo restores thermal bytes; `heat-brush128`; `inspector128`; `presets128` (every scenario loads, 600 ticks, no invalid ids/NaN); `keep-result128`; `palette-render128` byte-identical captures after the palette bump.
- **Performance (mains power, idle GPU, `tools/milestone/prepare_bench.gd` and the 256 soak):** running-source frame at 256 from ~15.0 ms to at most 18.0 ms with thermal on, at 128 from ~4.9 to at most 5.9 ms; >= 60 FPS at 128 on every Example; renderer video memory flat.

### Explicitly out of M1

Enthalpy-authoritative state and species mass calibration; conservation across species change; sun heating (sunvis is presentation-cadence); bulk convection of air heat back into voxels; explosions with pressure damage; electricity; rigid bodies/momentum; 512 or sparse worlds; new render pipelines; levels or scores.

### Risks

- Thermal cost: if 60 FPS at 128 is lost mid-milestone, conduct METAL every Nth tick or take the `R32F` fallback before cutting elements.
- Fire pinned temperature over-heating surroundings: tune `k_air`/`fire_temp`, gated by the wood-ignition pair of tests.
- Hydro remap over long runs: measure; fall back to run-mean mixing (documented closure).
- Six shaders share `Elem`: size mismatch fails silently; the sentinel unit check is mandatory in step 1.
- If Ben's sessions say "I cannot tell what is hot" or "materials look alike", redirect rendering to readability before more elements.
- If the thermal layer forces a change to the 4-byte cell record, stop and pull the M2 state owner forward.

## Milestone 2: "Power, blast and reuse" (outline)

Pay the engine debt in the first third: one owner for ordered edit transactions, state generations covering grid + thermal (+ charge), and fixed sim time; confirm delta undo covers all layers. Then **explosions**: `air_downsample` reserves `src.xyz` as an expansion source, `air_divergence` adds it, an EXPLOSIVE element with a stronger `air_coupling`, and a pressure-damage rule (BRICK with `strength` crumbles, WALL indestructible). **Electricity** as a third RGBA8 layer (charge, conductor timer): SPARK through METAL, BATTERY, SWITCH, LAMP, wires that heat and ignite (couples to M1). **Stamps/clipboard** as P3DA fragments with rotate, an Examples gallery with thumbnails, live-undo during Run. Tail: the bounded coupled-physics spike from status item 3 (pour, containment, pressure, heat transfer, moving obstacle) to feed the M3 decision.

## Milestone 3: one of two, decided by play evidence (outline)

- **A. Momentum and mechanics:** bring the APIC reference (`momentum-motion.md`, `mechanics-motion.md`) into production for liquids and powders behind the M2 state owner; particles carry mass, velocity, temperature; the grid stays the collision/render oracle; hydro and the enthalpy remap go away for particle-backed liquids; then rigid assemblies as a separate lane. Hard gate: the M2 spike meets agreed budgets.
- **B. Fidelity and scale:** 512 or sparse/active tiles, isosurface bisection, wall/water noise, pinholes, mesh-vs-raymarch comparison.
- Pick A if sessions end because "water feels like slime, nothing splashes or pushes"; pick B if because "world too small, too slow, looks wrong".

## Verification of this plan's execution

- Every worker unit: CPU suites headless, GPU suites via `python3 tools/milestone/verify.py --gpu --only ...` with `--output docs/milestone/<unit>-integrated`, coordinator reruns before cherry-pick, `docs/milestone/status.md` updated per integration.
- Milestone gate: all acceptance bullets above green on mains power with an idle GPU; a 10-minute play session by Ben with notes captured in `docs/milestone/heat.md`; `main` fast-forwarded and pushed as done for fundamentals.
