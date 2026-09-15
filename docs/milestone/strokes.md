# Strokes: every sample counts, paths stay connected

Placement milestone, contract 4 ([placement-brief.md](placement-brief.md)). Ben reported gaps on fast drags and clumps on slow ones.

## What changed

- **Every pointer motion event is a sample.** Build strokes on the workplane were already joined by the face-connected DDA, but surface strokes kept only the first and last ray of each frame. Now every accepted ray is kept (`pending_surface`, up to 64 per frame) and resolved in order by the GPU pick. Above 64 events in one frame the stream is thinned evenly (every second, then fourth, ...) so a stalled frame cannot queue an unbounded backlog; thinned samples are still joined by the DDA. `interaction_lab.gd` `_accept_sample`, `_sample`, `_flush`.
- **Surface joins follow the edge.** Two consecutive surface targets on the same face plane are joined by the straight face-connected line, as before. Across a corner (different normal) or a step (same normal, different plane) the line now goes through the projection of the new target onto the previous face plane, so it runs along the edge instead of breaking; `ONLY_AIR` leaves any solid it crosses intact. Toolbar crossings and picks that miss still break the segment. `voxel_sim.gd` `_surface_join`.
- **Live painting lays a line.** While an experiment runs, a moving brush deposits one stamp on every cell it crossed since its last sample, inside the next authoritative tick, in addition to the held source's own rate; a still brush keeps pouring by design (the Run tooltip says so). Workplane paths are the DDA between consecutive centres (`queue_live_path`); surface paths are the sampled rays, subdivided on the render thread so consecutive GPU-picked stamps land on adjacent cells (`queue_live_surface_path`, `_rt_interpolate_rays`, bounded by three model units of camera distance). Both queues are bounded (512 stamps per tick); cancel drops the queue, an intentional release keeps it. Quick clicks are unchanged.

## Evidence

- `tests/milestone/surface_stroke_gpu.gd` (`surface-stroke128`): sixteen rays per frame across a flat wall face leave one face-connected line that covers every path cell, identical to one ray per frame, walls preserved, exact undo; a stroke up the front face and back across the top face is one connected line through the diagonal edge cell with nothing written inside the solid; a missed sample breaks the segment.
- `tests/milestone/live_paint_input_gpu.gd` (`live-input128`): the still-pointer case now really is still (sub-pixel jitter) and keeps "exactly 24 grains over 120 ticks, identical at 1 or 16 samples per frame"; a new moving case drags 40 cells over a wall shelf and requires every crossed cell to hold a grain, identical at 1 or 16 samples per frame.
- `tests/milestone/paint_tools.gd` (`paint-tools`): 300 motion events in one frame are thinned yet leave a face-connected pending line; flush records it once and resets the count.

## Centre rule and the corner fixture

The targeting unit (contract 1) moved the additive surface centre from `cell + normal * (radius + 1)` to `cell + normal`. The stroke fixtures use radius 0, for which both rules give the same centre, so the expected cells are unchanged: the front-face line sits at z = 81 outside the slab face z = 80, the corner passes the edge cell (64, 95, 81) then (64, 96, 81) and (64, 96, 79) outside both faces. Build surface strokes now resolve a frame's rays in one batched pick (`pick_sync_batch`, one fence per 32 rays) against the state they were aimed at, then stamp in pointer order; a same-frame sample can no longer be picked against a stamp made earlier in the same frame, which is what keeps one and sixteen rays per frame identical on a flat face.

## Limits

- Surface live subdivision assumes the surface is within three model units of the camera; farther surfaces can still gap at very fast motion until the batch pick (contract 3) lets the render thread join picked targets exactly as Build does.
- Corner joins take the L-path through the projected cell; a step riser is not painted (the vertical leg crosses solid and `ONLY_AIR` skips it).
