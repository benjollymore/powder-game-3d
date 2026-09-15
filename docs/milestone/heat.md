# Heat and reactions milestone: consolidated handoff

Integration branch `milestone/heat` in `powder-game-3d-discovery/heat`, base `main` at `a18caec`. This document gathers what the milestone built, what it proves and what it leaves open. Contracts: [heat-brief.md](heat-brief.md). Roadmap and acceptance list: [heat-roadmap.md](heat-roadmap.md). Live status and follow-through: [heat-status.md](heat-status.md). Physics detail: [thermal-physics.md](thermal-physics.md). Rendering units: [powder-ripple.md](powder-ripple.md), [liquid-base.md](liquid-base.md). Evidence: [heat-integrated/](heat-integrated/).

## The temperature layer

Every cell carries a second authoritative record beside the four packed voxel bytes: an `R32G32_SFLOAT` texture whose R is temperature in kelvin and G is latent progress through a phase plateau. Energy is `E = C·T + G`, with `C` the element's `heat_capacity` per full cell, scaled for liquids by `amount / 200` without a floor (compressed liquid holds proportionally more). Temperature, not enthalpy, is authoritative because the cell record has no calibrated mass; the arithmetic (half-cell conductance, canonical operand order, `precise`) is ported from the earlier enthalpy references in `thermal_common.glslinc`.

The layer is state in every sense the brief demands (contract 3): swaps permute it with the voxel, columns and spread carry it with the moved units, hydro remaps it along each run's mass coordinate, regional history records 12 bytes per cell and restores both layers, Return and Keep cover it, archives carry it, and `VoxelSim.authoritative_textures()` lists both textures for every whole-world path. `request_state_readback` returns both layers from one render-thread job so tests compare the same tick. Whole-world replacements without thermal bytes initialise every cell to its element's `initial_temp` through `thermal_init.glsl`.

## Physics that now exist, and their limits

- **Conduction** runs inside the Margolus block across its twelve faces, each face moving the canonical transfer clamped to half the amount that would equalise the pair, applied in sequence. That is exactly conservative per face and obeys a maximum principle: a cell never leaves the range of its neighbours, so a checkerboard decays under the rotating partition offset and cannot oscillate. Wall is a perfect insulator; still air barely conducts; metal is the heat pipe. `dt` is one thermal second per tick (`thermal_speed` 120).
- **Flames are unbounded heat sources.** `pin_fire` holds any element with a `fire_temp` at that temperature before and after conduction, so energy is not conserved while fire burns, by design. A flame beside full water adds about 1.6 K per face per tick; a one-unit film reaches 618 K in one tick and boils in two.
- **Phase change** uses `settle`: above `hot_at` the excess goes into `G` and `T` stays on the plateau; below `cold_at` the deficit goes into `G`. Transition happens when `|G|` reaches the lower phase's `latent × heat_capacity × fill`. A cell already past its plateau by more than the latent energy changes phase at its own temperature. Species-change energy (the `G` dropped or created at transition, and the capacity jump between phases) is a declared non-conserved term.
- **Ignition** is a per-tick chance (`ignite_chance` 0.05) once a flammable is at or above its `ignition_temp`; ticks are fixed per simulated second, so it is independent of frame rate and of the speed slider.
- **Reactions** may require `min_t` and release `heat` kelvin into non-flame outputs; a liquid input that survives its own rule pays `cost` units (acid thins as it eats). A transmutation keeps temperature, zeroes latent and clears the element-specific flag bits.
- **Buoyancy** in `air_downsample.glsl` sums the excess of air and gas temperature over ambient, so plumes rise because they are hot rather than by a per-element constant.
- **Documented leaks.** Air displaced by liquid keeps or loses air's 0.001 J/K; the hydro remap keeps a 24-entry ring of rewritten donors and falls back to previous temperatures on longer runs. The falling-water test records the measured drift.
- **Known review findings still open** (with the thermal worker): a partial liquid cell that freezes or boils returns as a full cell, multiplying mass through a phase cycle; the hydro ring fallback writes new amounts under old temperatures, which a 64-cell horizontal front reproduces on the CPU port as a 4 percent energy loss; latent progress stays with a donor whose water leaves; steam condensation by temperature is unreachable in practice at steam's 0.05 J/K capacity, so the old probabilistic decay is what condenses it.

## Element catalogue

Ids 0 to 20; palette slots 32. Layers: 0 stone, 1 sand, 2 plant, 3 generic, 4 wood, 5 ice, 6 glass (flat), 7 pattern. Temperatures in kelvin.

| Id | Element | Category | Key behaviour | Hot / cold transition | Ignites at | Look |
|---|---|---|---|---|---|---|
| 0 | Air | gases | empty; carries temperature, capacity 0.001 | | | none |
| 1 | Wall | solids | immovable, insulating, immune to acid and void | | | stone layer |
| 2 | Sand | common | powder, heaps; acid eats it | | | sand layer, smooth |
| 3 | Water | common | liquid, levels, puts out fire | 373.15 → Steam / 273.15 → Ice | | volume, foams |
| 4 | Steam | gases | rises, drifts | cold 373.15 → Water (and decay) | | medium |
| 5 | Fire | heat | flame pinned at 1200; ignites and boils | | | emissive medium |
| 6 | Plant | solids | grows into water; leaf cards | | 520 | plant layer |
| 7 | Oil | liquids | floats on water | | 500 | volume |
| 8 | Smoke | gases | rises from fire, clears | | | medium |
| 9 | Wood | solids | burns slowly | | 570 | wood layer |
| 10 | Ice | heat | immovable frozen water | hot 273.15 → Water | | ice layer (cracks) |
| 11 | Lava | heat | emissive opaque liquid, crusts | cold 1000 → Stone | | volume, glow, opacity 12 |
| 12 | Stone | solids | immovable rock | hot 1300 → Lava | | stone layer, rough |
| 13 | Metal | solids | conductivity 50, the heat pipe | | | flat layer, low roughness |
| 14 | Wax | solids | soft solid | hot 330 → Molten wax | | flat layer |
| 15 | Molten wax | liquids | slow dim emissive liquid, feeds a flame | cold 325 → Wax | 640 | volume, opacity 5 |
| 16 | Gunpowder | powders | fuse timer in flag bits 4..6, seven ticks | | 420 | sand layer, dark coarse |
| 17 | Gas | gases | flammable rising gas, flashes on fire | | 500 | faint medium |
| 18 | Acid | liquids | pair rules eat sand, plant, wood, ice, wax, gunpowder, stone, metal; thins by `cost` | | | volume, no foam, opacity 2 |
| 19 | Clone | special | arms from the first solid, powder or liquid partner and emits it | | | pattern layer |
| 20 | Void | special | swallows any partner but wall and specials | | | matte generic layer |

Clone, void and the fuse read only block partners (`rule_special`), so they are deterministic under the partition; `RULE_NO_SPECIALS` disables them. Id 21 (Glass) is reserved and unimplemented.

## Editor surface

- **Palette** grouped by category: Common (Sand, Water, Wall), Heat (Fire, Ice, Lava, Heat and Cool brushes), then tabs per category, each button with the row's `tip`. Number keys map to the first row.
- **Heat and Cool brushes** add or subtract kelvin with radial falloff in the thermal layer without touching voxel bytes; painted material starts at its `initial_temp`; erased cells keep their temperature. Heat then cool restores bytes exactly at radius 3.
- **Hover inspector**: the status line names the cell under the pointer with temperature and fill ("Water · 69 °C · full"), through the pick record's spare bytes, never a full readback.
- **Speed slider** from one eighth to four times, bound to the time controller; Pause and Step remain.
- **Examples** load any scenario (Demo, Dam break, U-bend, Pressure pipe, Forest fire, Oil spill, Steam vent, Candle, Powder keg, Acid rain, Empty) as a new authored build through the unsaved-build guard.
- **Keep result** turns the running experiment into one undoable authored revision by capturing changed tiles; Return keeps its meaning.
- **Archive v2** (`material-seed-amount-flags-rgba8+temperature-latent-rg32f-v2`) stores both layers with per-layer hashes; a version-1 file opens with default temperatures.

## Rendering changes

Per-element shader arrays widened from 16 to 32 with zero-padded uploads (byte-identical on every existing scene). A thermal incandescence ramp (dull red at 800 K to yellow-white by 1500 K) on opaque and liquid surfaces, off by default and bound by the editor presentation. Ice, glass and pattern texture layers, and a readable default look for every new id through the existing per-id keys. Liquid self-illumination accumulates by its own density so lava and acid glow. Per-liquid foam and opacity multipliers: lava, molten wax and acid hide what they cover and cast no water caustics (the bright streaks at a lava block's base were the slab's caustics seen through a water-clear liquid, not droplets). Powder heap rings were removed by shading smoothed powders from coarser fields, with section caps and embedded cameras keeping their override normals.

## Verification inventory

From [heat-integrated/](heat-integrated/) on the clean integration tree (check counts as printed by each suite):

| Area | Suites and checks |
|---|---|
| Physics | `physics128` 129; `thermal-state128` 24; `cadence128` 40 with thermal bytes across batch schedules; CPU `thermal-init` 16, `thermal-remap` 25 |
| Editor | `heat-ui` 32 and `heat-ui128` 20; `keep-result` 15; `cell-inspector` 11 and `inspector128` 8; `archives-thermal128` 15; `archive-format` 24; `examples` 66 at each grid; file shortcuts 24 CPU and 20 GPU; document protection 32 at 128 and 31 of 32 at 256; pending paint 28 with 2 failures (open item) |
| Rendering | `palette128` 60; `liquid-base128` 32; `ripple128` 51; surfaces 99; sprites 40; capacity 112; overflow interface 66; ordinary interface 119; liquid section 61; liquid exit 102 |
| Existing regressions | regional undo, redo at both grids, live emitter 34, live click 19, actions 14, workflow 24, interaction 20, trackpad 27, gestures, history guards, guard queue, archives, world FIFO 13 |

No frame-time or cost number is quoted here; the thermal bench, the paired cost fixtures and the example captures must be run on mains power with an idle GPU (see the measurement rule in [heat-status.md](heat-status.md)).

## Open items

See the follow-through list in [heat-status.md](heat-status.md): the two asynchronous-Open failures, the Volcano, Ice cave, Boiler and Foundry showcase scenarios with their tests and glow captures, once-per-centre heat stamping and a surface-target heat mode, the thermal review findings above, and the mains-power runs and the ten-minute play session that gate the milestone.

## Reproduction

```sh
cd /Users/benjo/.superset/projects/powder-game-3d-discovery/heat
godot --headless --path . --import
python3 tools/milestone/verify.py --output docs/milestone/heat-verification
python3 tools/milestone/verify.py --gpu --output docs/milestone/heat-verification
godot --path . -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/milestone/thermal_bench.gd -- grid=128 output=/tmp/thermal-bench-128.json
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/milestone/capture_examples.gd -- grid=128 seconds=4 output_dir=/tmp/examples-capture
```
