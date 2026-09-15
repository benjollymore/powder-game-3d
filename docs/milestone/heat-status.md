# Heat milestone status

Updated 2026-09-15. Integration checkout `powder-game-3d-discovery/heat`, branch `milestone/heat`, base `main` at `a18caec`. Brief and contracts: [heat-brief.md](heat-brief.md). Roadmap and acceptance: [heat-roadmap.md](heat-roadmap.md). Previous milestone: [status.md](status.md).

## Current result

The editor now has a real temperature layer. Every cell carries temperature and latent progress in an `R32G32_SFLOAT` texture that moves with material through swaps, columns and hydro redistribution. Heat conducts inside each Margolus block; elements melt, freeze, boil and condense through data-driven hot/cold transitions with a latent plateau; flammables ignite by temperature; fire is pinned to its flame temperature; reactions can be temperature-gated and release heat; hot gases drive the air solver's buoyancy. Ten new elements (Ice, Lava, Stone, Metal, Wax, Molten wax, Gunpowder, Gas, Acid, Clone, Void) have readable looks, categories and tooltips; the palette is grouped by category with Heat and Cool brushes, a speed slider, an Examples picker, a hover inspector ("Water · 69 °C · full"), Keep-result, and version-2 archives that carry temperature.

Integrated on `milestone/heat` at `48f64ff` (base `main` `a18caec`). Independent reviews rotated between workers found and closed: wrong-table initial temperatures and energy totals, a same-tick out-of-block read race in clone/fuse rules, element flags surviving transmutation, a readback FIFO that paired temperatures from the wrong request, a lambda callable left on the rendering device at quit, a non-compiling brush kernel, a capacity floor that created mass through freezing, and a section-cap normal regression from the earlier ripple change.

## Integrated

- Element schema v2 (`dfdbaa7`), palette 32 (`94465ec`), thermal plumbing (`1bd5838`), editor palette/speed/Examples/Keep (`0517c08`), tranche B elements and rules (`ae74e54`, `5ac678a`, `096e78c`), rendering looks, glow scaffold, ice/glass/metal/clone layers, per-liquid opacity (`ca108df`, `eb7e459`, `4415559`, `91e09ef`, `dfdf2f8`), editor thermal unit with archive v2 and inspector (`4ff0892`, `25b51ea`, `e901c00`, `4cd9a0e`, `a0e04a8`), thermal physics (`a5d8d1e`, `ae3dc21`), thermal bench script (`48f64ff`).
- Coordinator verification on the clean tree: 25 CPU suites; 28 of 30 GPU suites including physics 129, thermal state 24, cadence 40 with thermal bytes across batch schedules, palette 60, liquid base 32, protection at 128, redo at both grids, and every rendering suite, all with clean exits. [Evidence](heat-integrated/).

## Active follow-through

1. Two asynchronous-Open failures (document-protection at 256 "Save As during dirty Open", pending-paint "saved fixture available for Open completion" and "Open completion cannot overwrite a newer Undo") are with the editor worker.
2. Showcase scenarios Volcano, Ice cave, Boiler and Foundry with their physics tests (elements worker); glow captures of lava, stone and metal once they exist (rendering worker).
3. Heat brush once-per-centre stamping in Build and a surface-target heat/cool mode (editor worker).
4. Independent review of the thermal physics kernel (rendering worker) and of the showcase scenarios.
5. Run `tools/milestone/thermal_bench.gd` and `tools/milestone/capture_examples.gd` on mains power with an idle GPU; the 10-minute play session; `docs/milestone/heat.md` consolidating the physics, element and editor docs.

## Measurement rules

No frame-time or cost claim unless mains power and an idle GPU, stated in the evidence. Ben's Godot may be open in another worktree; never kill it.
