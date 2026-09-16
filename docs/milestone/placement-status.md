# Placement milestone status

Updated 2026-09-15. Integration checkout `powder-game-3d-discovery/placement`, branch `milestone/placement`, base `main` at `2de95a1`. Brief, root causes and contracts: [placement-brief.md](placement-brief.md). Previous milestone: [heat-status.md](heat-status.md).

## Current result

Milestone opened after Ben's report that placement is janky and solids come out as blobs. Root causes are pinned to code in the brief: additive surface stamps centred radius+1 outward, a preview pick that clears on any pointer motion, centre-plane workplane targeting, first-and-last-only surface sampling, no live-paint path interpolation, and one sphere brush for every material. Three workers started: tools (brush shapes, ghost preview, Line and Box), targeting (batch picks, always-on preview, surface and workplane centring), strokes (full sampling, DDA joining, live path interpolation).

## Integrated

- **Brush shapes** (`3a9c33e`, `4562e8c`): sphere, cube and disc with per-material defaults so immovables paint as boxes; Shape button and key C. Cube and disc are bounded to the radius box the undo capture covers, after they were found writing whole 8-cell dispatch groups.
- **Targeting** (`692e3cf`, `8a3da07`): batch surface picks, 32 rays per dispatch; a preview pick every frame with monotonic request ids so the marker never blanks during motion; additive surface stamps centred on the first air cell outside the hit face instead of `radius + 1` cells away; workplane targeting on the visible slab face.
- **Strokes** (`ae07042`, `bb58468`): every pointer event sampled, thinned above 64 per frame; surface strokes joined by DDA on a face and around corners, with joins broken rather than bored through material; live painting laid along the path; and a per-stroke written mask so a stroke never re-targets its own fresh paint, which had let a wide brush climb its own cap into a tower.
- **Ghost preview and tools** (`9255876`, `14f8289`, `67ff061`): a compute pass mirrors the stamp's own decision into a cell mask drawn as translucent cubes, replacing the sphere cursor; two-click Line and Box tools; a dedicated box-erase mode; stale tool anchors dropped on every world or mode change; the heat ghost kept spherical to match its stamp; the sidebar back inside a 1280x800 window.
- **Fly navigation** (`54e397e`): optional WASD, Q and E, Shift to sprint, off by default, remembered between sessions, sharing one implementation with the scenario viewer's free camera. A focused text field swallows the keys.
- **Harness** (`dac0ae9`, `2065b3d`, and the pathology-guard change): suites may declare their own watchdog, the 256 scenario build gets 300 s, a wall-clock budget that failed under load is now a loose pathology guard, and the fly suite's stub editor gets the nodes its frame loop places. Each of these was a false failure that would have hidden a real one.
- Coordinator verification: **30 CPU suites** and 20 of 22 GPU suites green before the last two units; the full GPU batch is queued behind a rendering investigation.

## Active follow-through

1. Full GPU batch on the integrated tree, including the fly parity case and the tool suites, once the rendering investigation releases the lease.
2. A separate investigation into the lattice of holes and blown-out white Ben reported on `main`, reproduced against both the heat milestone and the commit before it.
3. Ben's feel test of placement, then merge to `main`.
