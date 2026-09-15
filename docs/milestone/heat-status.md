# Heat milestone status

Updated 2026-09-15. Integration checkout `powder-game-3d-discovery/heat`, branch `milestone/heat`, base `main` at `a18caec`. Brief and contracts: [heat-brief.md](heat-brief.md). Roadmap and acceptance: [heat-roadmap.md](heat-roadmap.md). Previous milestone: [status.md](status.md).

## Current result

The editor now has a real temperature layer. Every cell carries temperature and latent progress in an `R32G32_SFLOAT` texture that moves with material through swaps, columns and hydro redistribution. Heat conducts inside each Margolus block; elements melt, freeze, boil and condense through data-driven hot/cold transitions with a latent plateau; flammables ignite by temperature; fire is pinned to its flame temperature; reactions can be temperature-gated and release heat; hot gases drive the air solver's buoyancy. Ten new elements (Ice, Lava, Stone, Metal, Wax, Molten wax, Gunpowder, Gas, Acid, Clone, Void) have readable looks, categories and tooltips; the palette is grouped by category with Heat and Cool brushes, a speed slider, an Examples picker, a hover inspector ("Water · 69 °C · full"), Keep-result, and version-2 archives that carry temperature.

Integrated on `milestone/heat` at `e9a4f20` and fast-forwarded to `main` (base `main` `a18caec`). Independent reviews rotated between workers found and closed: wrong-table initial temperatures and energy totals, a same-tick out-of-block read race in clone/fuse rules, element flags surviving transmutation, a readback FIFO that paired temperatures from the wrong request, a lambda callable left on the rendering device at quit, a non-compiling brush kernel, a capacity floor that created mass through freezing, and a section-cap normal regression from the earlier ripple change.

## Integrated

- Element schema v2 (`dfdbaa7`), palette 32 (`94465ec`), thermal plumbing (`1bd5838`), editor palette/speed/Examples/Keep (`0517c08`), tranche B elements and rules (`ae74e54`, `5ac678a`, `096e78c`), rendering looks, glow scaffold, ice/glass/metal/clone layers, per-liquid opacity (`ca108df`, `eb7e459`, `4415559`, `91e09ef`, `dfdf2f8`), editor thermal unit with archive v2 and inspector (`4ff0892`, `25b51ea`, `e901c00`, `4cd9a0e`, `a0e04a8`), thermal physics (`a5d8d1e`, `ae3dc21`), thermal bench script (`48f64ff`).
- Showcase scenarios Volcano, Ice cave, Boiler and Foundry with physics tests (`d116453`), carried-amount phase change and the three-dispatch hydro heat remap (`3dadf78`, `b08faba`), surface heat/cool and once-per-centre stamping (`db23b2b`), archive defaults for omitted layers (`5038c17`), the Examples capture tool (`4cd9a0e`) and the consolidated [heat.md](heat.md) (`a58fcc4`).
- Coordinator verification on the clean tree: 25 CPU suites; all 30 GPU suites including physics 150 (all 74 legacy checks intact), thermal state 24, cadence 40 with thermal bytes across batch schedules, palette 60, liquid base 32, surface 42, protection at both grids, pending paint, redo at both grids, thermal archives, inspector and every rendering suite, all with clean exits; 15 Examples load, run and Return exactly. [Evidence](heat-integrated/).

## Active follow-through

1. Lava and ice looks fixed (`e9a4f20`: editor palette overrides no longer glow, ramp holds orange at 1500 K, ice albedo deep blue; 17 checks against pinned pre-change shaders). The volcano lake still reads peach rather than deep orange; one palette value if wanted.
2. Thermal cost at 256: paired on/off deltas of 5 to 7 ms per frame (throttled, Low Power Mode) against a 3 ms budget. Five reductions are integrated behind flags defaulting off (`a256102`: skip all-air blocks, skip unchanged hydro runs, buoyancy subsampling, thermal every second tick, block early-out; `variant=` on the bench). Rerun `tools/milestone/thermal_bench.gd` on mains power with `variant=all` and each flag before choosing defaults.
3. Ben's 10-minute unguided play session and the seven chain reactions from Examples; frames from `tools/milestone/capture_examples.gd` are in [heat-examples](heat-examples/).
4. The intermittent heat-ui GPU abort at the Keep click is instrumented (`546f407`); if it recurs the new check records the editor state.
5. `docs/milestone/heat.md` consolidates the milestone; keep it current as items 1 and 2 land.

## Measurement rules

No frame-time or cost claim unless mains power and an idle GPU, stated in the evidence. Ben's Godot may be open in another worktree; never kill it.
