# Heat milestone status

Updated 2026-09-15. Integration checkout `powder-game-3d-discovery/heat`, branch `milestone/heat`, base `main` at `a18caec`. Brief and contracts: [heat-brief.md](heat-brief.md). Roadmap and acceptance: [heat-roadmap.md](heat-roadmap.md). Previous milestone: [status.md](status.md).

## Current result

Milestone opened. All four first units are integrated. In flight: thermal physics (conduction, phase change, gated reactions, transfer contract, brushes, tranche A elements), tranche B elements and scenarios, ICE/GLASS layers and the glow scaffold, and the editor inspector/archive v2 plus the Keep fixes.

## Integrated

- Element schema v2 (`dfdbaa7`): 80-byte shared `Elem` record, category/tip keys, provisional thermal coefficients, reaction min_t/heat encoding; 48 unit checks.
- Palette 32 (`94465ec`) with byte-identical captures (17 checks); `PALETTE_SIZE = 32`, unused ids transparent.
- Thermal layer plumbing (`1bd5838`): `R32G32_SFLOAT` texture, per-element initialisation, swap permutation, 12-byte regional records, probe payload; thermal state 23 checks, cadence 30 including thermal bytes. Texture3DRD accepts FORMAT_RGF (day-1 check passed).
- Editor unit 1 (`0517c08`): categorised palette with tooltips, speed slider, Examples, Keep result. Two Keep GPU checks and three palette-fallback CPU checks fail on the integrated branch and are back with the editor worker.
- Coordinator reruns: physics 74, regional 17 at 256, surface 36, capacity 112, and 24 further GPU suites pass; test byte expectations updated for 12 bytes per cell.

## Active follow-through

1. Integrate the two mechanical prerequisites (schema v2, palette 32) with byte-identical captures, then reset all worker worktrees onto them.
2. Thermal physics (conduction, phase change, gated reactions, transfer contract, buoyancy, brushes) and tranche A elements.
3. Tranche B elements, scenarios and CPU oracle.
4. Editor inspector, archive v2, glow and material layers.
5. Bench on mains power with an idle GPU; 10-minute play session; docs.

## Measurement rules

No frame-time or cost claim unless mains power and an idle GPU, stated in the evidence. Ben's Godot may be open in another worktree; never kill it.
