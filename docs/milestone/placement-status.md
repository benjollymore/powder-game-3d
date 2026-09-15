# Placement milestone status

Updated 2026-09-15. Integration checkout `powder-game-3d-discovery/placement`, branch `milestone/placement`, base `main` at `2de95a1`. Brief, root causes and contracts: [placement-brief.md](placement-brief.md). Previous milestone: [heat-status.md](heat-status.md).

## Current result

Milestone opened after Ben's report that placement is janky and solids come out as blobs. Root causes are pinned to code in the brief: additive surface stamps centred radius+1 outward, a preview pick that clears on any pointer motion, centre-plane workplane targeting, first-and-last-only surface sampling, no live-paint path interpolation, and one sphere brush for every material. Three workers started: tools (brush shapes, ghost preview, Line and Box), targeting (batch picks, always-on preview, surface and workplane centring), strokes (full sampling, DDA joining, live path interpolation).

## Integrated

Nothing yet.

## Active follow-through

1. Tools unit 1: shapes and the shape push constant, sphere byte-identical.
2. Targeting unit 1: batch pick API, preview scheduling, centring rules with the test rewrite.
3. Strokes unit 1: per-frame sampling, live path interpolation, surface stroke joining.
4. Ghost preview, Line and Box tools; cross-reviews; Ben's feel test.
