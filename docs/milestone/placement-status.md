# Placement milestone status

Updated 2026-09-15. Integration checkout `powder-game-3d-discovery/placement`, branch `milestone/placement`, base `main` at `2de95a1`. Brief, root causes and contracts: [placement-brief.md](placement-brief.md). Previous milestone: [heat-status.md](heat-status.md).

## Current result

Milestone opened after Ben's report that placement is janky and solids come out as blobs. Root causes are pinned to code in the brief: additive surface stamps centred radius+1 outward, a preview pick that clears on any pointer motion, centre-plane workplane targeting, first-and-last-only surface sampling, no live-paint path interpolation, and one sphere brush for every material. Three workers started: tools (brush shapes, ghost preview, Line and Box), targeting (batch picks, always-on preview, surface and workplane centring), strokes (full sampling, DDA joining, live path interpolation).

## Integrated

- Brush shapes (`3a9c33e`, `4562e8c`): sphere, cube and disc with per-material defaults (immovables cube), Shape button and key C; cube and disc bounded to the radius box the undo capture covers. Brush-shape 16 checks; sphere byte-identical everywhere (physics 150).
- Targeting (`692e3cf`, `8a3da07`): batch surface pick (32 rays per dispatch), preview pick every frame with monotonic ids and a target that survives motion, additive surface centre on the first air cell outside the hit face, workplane target on the visible slab face. Surface 46, preview-pick 11, interaction unit 25.
- Strokes (`ae07042`): every pointer event sampled (thinned above 64 per frame), surface strokes joined by DDA on a face and L-paths around corners, live painting laid along the path, batch pick per frame in the recorder. Two of its GPU suites still fail (flat-face 1-vs-16 identity; live-input off by one grain and missing crossed cells) and are back with the strokes worker together with a new rule: a stroke never re-targets its own fresh paint (a wide surface brush was climbing its own cap into a tower).

## Active follow-through

1. Strokes: fix the two failing GPU suites and land the no-self-retargeting rule.
2. Tools unit 2: ghost preview of the exact cell set, Line and Box tools, sidebar fitting 1280x800 (two surface-feedback layout checks currently fail).
3. Review of the shapes and strokes units (targeting worker); Ben's feel test; merge to main.
