# Heat milestone status

Updated 2026-09-15. Integration checkout `powder-game-3d-discovery/heat`, branch `milestone/heat`, base `main` at `a18caec`. Brief and contracts: [heat-brief.md](heat-brief.md). Roadmap and acceptance: [heat-roadmap.md](heat-roadmap.md). Previous milestone: [status.md](status.md).

## Current result

Milestone opened. Four workers started in parallel on their first units: elements (table v2 schema and shared `Elem` include), rendering (palette 16 to 32), thermal (thermal texture, bindings, swap permutation, regional history, probe payload), editor (categorised palette, time scale, Examples, Keep result).

## Integrated

Nothing yet.

## Active follow-through

1. Integrate the two mechanical prerequisites (schema v2, palette 32) with byte-identical captures, then reset all worker worktrees onto them.
2. Thermal physics (conduction, phase change, gated reactions, transfer contract, buoyancy, brushes) and tranche A elements.
3. Tranche B elements, scenarios and CPU oracle.
4. Editor inspector, archive v2, glow and material layers.
5. Bench on mains power with an idle GPU; 10-minute play session; docs.

## Measurement rules

No frame-time or cost claim unless mains power and an idle GPU, stated in the evidence. Ben's Godot may be open in another worktree; never kill it.
