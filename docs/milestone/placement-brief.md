# Milestone: Placement that lands where you point

Start: 2026-09-15. Base: `main` at `2de95a1` (heat milestone merged). Integration branch `milestone/placement` in `powder-game-3d-discovery/placement`. Rules from [brief.md](brief.md) and [heat-brief.md](heat-brief.md) apply: GPU state authoritative, edits as ordered commands, one visible GPU process at a time assigned by the coordinator, no timing claims unless mains power and idle GPU.

Ben's report: "Placing solids is a blob and super janky. Placement in general is super janky." Symptoms confirmed: the brush lands in the wrong place, fast drags leave gaps and slow drags clump, and walls come out as rounded blobs. No stutter. Reference: WorldPainter brush (surface-following, shape and size, a preview of what will change), with box and line tools one click away.

## Root causes (from the source inventory, file:line at `2de95a1`)

1. `shaders/compute/editor/surface_pick.glsl:62` places an additive stamp at `cell + normal * (radius + 1)`, so the sphere only tangents the surface; at radius 3 the material floats four cells off the face and diagonal faces get the offset on one axis only.
2. `scripts/discovery/interaction_lab.gd:1502-1509` `_request_preview` hashes the ray into the pick signature, so any pointer motion clears `pick_cache`, the target becomes invalid and the marker hides; a shown target is always from an older stationary ray, two or three frames late (two render-thread hops plus a deferred call), one pick in flight, 50 ms throttle in Test.
3. Workplane targeting (`scripts/sim/edit_geometry.gd:4-18`) intersects the plane through cell centres; at grazing angles the chosen cell is not the one under the visible face.
4. `interaction_lab.gd:1529-1538` keeps only the first and latest surface ray per frame; intermediate motion is discarded and joining is left to a face test on the GPU (`voxel_sim.gd:640-642`), which breaks the segment when normals differ: gaps and jumps.
5. Test-mode live painting (`interaction_lab.gd:1603-1635`, `voxel_sim.gd:463`) has no path interpolation; a stationary pointer deposits at 24 stamps/s (clump) and a fast drag deposits the same 24/s spread along the path (gaps).
6. `shaders/compute/editor/brush.glsl:63-70` and `surface_stamp.glsl:30-32` stamp one Euclidean ball for every material; box modes exist only for region fill; `elements.gd` `smooth` is renderer-only. The cursor is a `SphereMesh` scaled to the diameter (`interaction_lab.gd:153-158`), not the cells that will change. Region fill is hidden under "Tools & view options"; there are no line, box-draw or plane tools.

## Outcome

Point at a surface or workplane, see exactly which cells will change, click or drag, and get exactly those cells, connected along the path, in the shape the material deserves: boxes and lines for walls and solids, round brushes for powders and liquids.

## Contracts (pinned)

1. **Surface placement.** An additive surface stamp is centred on the first air cell outside the hit face (`cell + normal`), and `ONLY_AIR` keeps the solid intact, so the brush forms a cap sitting on the surface; erase is centred on the hit cell. `pick.target` carries that centre. The old `radius + 1` rule and its test line "radius-three add centers brush outside the selected solid surface" are replaced with "radius-three add sits on the selected surface (at least one stamped cell is face-adjacent to the hit cell)".
2. **Workplane placement.** The target cell is the cell whose visible face the ray crosses on the workplane slab (enter the slab `[cell, cell+1)` along the plane axis and take the first cell the ray is inside), not the centre-plane intersection; identical to today for rays near perpendicular.
3. **Preview and pick scheduling.** A preview pick is issued every frame the pointer is over the scene, whether or not it moved; the last valid pick stays displayed until a newer one arrives (never hidden by motion); results are tagged with a monotonically increasing request id and only a newer id replaces the shown target; the Test-mode throttle goes. `VoxelSim.request_surface_picks(rays: Array, callback)` picks up to 32 rays in one dispatch (one 64-byte record each) so a frame's motion samples resolve together; single-ray callers keep working.
4. **Strokes.** Every pointer motion event in a frame is a sample (cap 64 per frame, evenly thinned above); surface samples are batch-picked and joined by a face-connected DDA between consecutive targets when they lie on the same face plane, and by the shortest connected path through the picked targets otherwise, so a fast drag across a flat face never gaps; a segment still breaks at toolbar crossings and when the pick misses. Test-mode live painting interpolates the path: each cell along the path receives one stamp per crossing, and a stationary brush keeps emitting at the source rate (a held source is a fountain by design, stated in the tip).
5. **Brush shapes.** `Brush.Shape { SPHERE, CUBE, DISC }` with radius semantics: sphere = ball of radius r; cube = axis-aligned box `[c - r, c + r]`; disc = one-cell-thick square on the workplane (surface: on the hit face plane). `brush.glsl` and `surface_stamp.glsl` take the shape in the push constant; region fill stays a box. Default shape per element category: `solids` and `special` cube, everything else sphere; the user can override per session. Stroke centres are stamped at every DDA cell for sphere and disc, and for cube a segment of cubes is the union along the DDA (no spacing gaps).
6. **Ghost preview.** Before the click lands, the editor draws the exact cell set the stamp will change (respecting ONLY_AIR and the section cut) as a wire or translucent cube instance set at the current target, updated every frame; the applied stamp's changed cell set equals the previewed set for a stationary pointer (GPU test compares the two).
7. **Tools.** Top-level buttons beside Erase: Shape (sphere, cube, disc), Line (two clicks: a connected DDA of the current brush between the two targets), Box (two clicks on the workplane or surface: filled axis-aligned box, current material, ONLY_AIR); region select stays under advanced. Keys: `[`/`]` radius as now, `C` cycles shape, `L` line, `K` box (check they do not collide with existing keys in `_unhandled_input`).

## Ownership

| Worker | Worktree / branch | Owns |
|---|---|---|
| targeting | `placement-targeting` / `milestone/placement-targeting` | contracts 1-3: `surface_pick.glsl`, batch pick in `voxel_edit_gpu.gd` and `voxel_sim.gd`, `edit_geometry.gd` target rule, `_request_preview`/`_receive_pick`/`pick_cache` in `interaction_lab.gd`, surface_pick and preview GPU tests |
| strokes | `placement-strokes` / `milestone/placement-strokes` | contract 4: `_sample`, `pending_surface`, `Geometry.stroke`, `pending_gesture.gd`, `_rt_record_surface_stroke` joining, live emitter path interpolation in `voxel_sim.gd`/`live_emitter`, stroke GPU tests |
| tools | `placement-tools` / `milestone/placement-tools` | contracts 5-7: `brush.gd` Shape, `brush.glsl`/`surface_stamp.glsl` shape param, ghost preview, Shape/Line/Box UI and keys, per-category defaults in `palette_panel.gd`, tool CPU and GPU tests |
| coordinator | `placement` / `milestone/placement` | contracts, cherry-pick integration, reruns, GPU lease, reviews, status |

`interaction_lab.gd` is shared by function: targeting owns `_target_at`, `_ray_at`, `_request_preview`, `_receive_pick`; strokes owns `_sample`, `_flush`, `_set_live_source`; tools owns `_build_ui` additions, the cursor/preview nodes, `_brush_mode`, `_unhandled_input` key additions. `voxel_edit_gpu.gd` is shared: targeting owns pick, strokes owns stroke capture, tools owns stamp push constants. Agree signatures before depending on them; the coordinator resolves overlaps.

## Order of landing

1. tools: `Brush.Shape` and the shape push constant with sphere behaviour byte-identical (all suites green), then the ghost preview, then Line/Box.
2. targeting: batch pick API and preview scheduling (single-ray behaviour unchanged), then the surface centre rule and workplane face rule with the test rewrite.
3. strokes: full per-frame sampling with batch pick, DDA joining, live path interpolation.

## Acceptance

- Stationary pointer over a surface or workplane: the applied stamp's changed cell set equals the previewed set (GPU test, both modes, all three shapes).
- The preview marker is visible on every frame the pointer is over a valid target while moving (no frame with a hidden marker in a 60-frame drag); a newer target replaces an older one within one frame of the pick returning.
- Radius-three additive surface stamp: at least one changed cell is face-adjacent to the hit cell; erase changes the hit cell.
- Fast parsed drag at 16 samples per frame across a flat face and across a two-face corner: face-connected changed set, identical at 1 and 16 samples per frame for the flat face; wall cells preserved.
- Test-mode drag at 16 samples per frame: every cell along the pointer path receives at least one deposit; stationary brush still deposits 24 per second.
- Cube brush of radius 2 on a workplane changes exactly the 5x5x5 box minus non-air cells; Line and Box tools change exactly the expected sets; solids default to cube.
- All existing CPU and GPU suites green, with the one surface centring check rewritten and its reasoning in the doc.
- Ben's feel test: paint a wall, a sand pile, a water pour and a wire of metal without fighting the brush.

## Rules

Same as the heat brief: small commits on your branch, never rebase another worker's branch, the coordinator cherry-picks; CPU and `--headless --check-only` freely; visible GPU runs only under a granted lease, `--import` first, end your turn to release; commit new `.uid` files and new-kernel `.import` files, never tracked `.import` churn; report evidence and risks; Ben's Godot may be open elsewhere, never kill it.
