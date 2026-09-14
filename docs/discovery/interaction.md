# Paint-first interaction discovery

The recommended direction is a paint-first sandbox with a dependable editing core: choose a material, see exactly where the brush will land, paint while paused or playing, and opt into precise construction tools when needed. This prototype uses the existing GPU simulation and renderer; it does not introduce duplicate physics or endorse the dense-world architecture as final.

Reference synthesis: WorldPainter supplies the accessible brush/material emphasis; Amulet/MCEdit supply structural selection and explicit editing tools; Besiege supplies the build, run, return-to-build loop. WorldEdit's two-corner regions and masks remain useful concepts, secondary to the direct paint workflow. Root coordination notes contain the reference research; this prototype is an experiment in those principles, not a claim of parity with those products.

## Run it

From this worktree:

```sh
godot --path . res://scenes/discovery/interaction.tscn -- grid=128
```

The default main scene is unchanged. Omit `grid=128` to try the project's 256³ setting; the bounded acceptance run uses 128³. Begin with the provided tank and water. Choose Water or Sand and draw across the tank's walls: placement fills empty cells and preserves occupied cells. Press Space to run, paint additional live material, then Space to return to the exact authored voxel arrangement. Live edits are discarded on return, and live undo is unavailable.

- Palette, brush radius and Run are at the top. Left drag paints; Paint/erase or X explicitly changes destructive mode. Radius zero paints a single cell.
- Right drag orbits; wheel zooms; V faces the active plane; F gives an angled view.
- X/Y/Z plane buttons select the construction axis. Shift-wheel moves by exactly one cell; the numeric field selects any cell directly. The preview and coordinates show the intended brush center. Grid guides are coarse; the numeric target is exact.
- Region tool/B switches to two-corner selection. Click a corner, change the plane depth if needed, click the second corner. Bounds and inclusive dimensions appear. Fill selected region fills empty cells with the selected material.
- Ctrl/Cmd-Z or Undo restores the last build edit, including the original per-cell seed and liquid amount. Reset container is explicitly destructive and clears history.
- Section view hides the positive side of the selected plane without deleting material. All four sprite layers and both raymarch passes receive the same clipping controls.

The legacy main scene's real-time reset moved from the conflicting `1` to Backslash. Play now recovers from zero time scale. The discovery editor owns its build/run input and disables the simulation node's destructive legacy hotkeys.

## Implementation decision

Separate targeting, edit commands and simulation state. The pure geometry helper converts a camera ray into a fixed construction-plane cell; changing camera depth does not slide the target along a box-entry ray. Stroke interpolation produces a face-connected digital line even for radius zero. This deliberately overcovers diagonal crossings by at most one cell so a one-cell construction stroke cannot have diagonal gaps.

`VoxelSim.paint_stroke(centers, radius, element, mode)` submits ordered sphere stamps in one compute list and rebuilds derived fields once for the batch. The existing ONLY_AIR kernel policy preserves walls and existing materials. `paint_region(lo, hi, element)` takes half-open bounds and uses one box dispatch with the same occupancy mask. This avoids issuing a whole-world field rebuild for every interpolated point. The whole-world rebuild still exists; this is a command-batching improvement, not a scaling solution.

The editor defaults to additive painting. Region tools, numeric controls and section inspection serve precise work without forcing every casual stroke through a selection workflow. Plane-first targeting is useful for construction and inspecting experiments. Surface-following and free emission still need separate tools; a single workplane should not become the only long-term painting mode.

Build undo and run/restore use full GPU voxel snapshots as a deliberately simple discovery fallback. Build edits wait for an asynchronous callback delivering a GPU readback before mutation; undo history has a 128 MiB voxel-data cap (16 entries at 128³, two at 256³). These copies can stall the GPU and are not the proposed production undo architecture. A separate build snapshot is retained during play. Restoring it resets the voxel world and air through the current upload path; it is not a rewind of every transient FX pool or the full simulation history.

## Evidence

CPU geometry checks: 20 passed, zero failures. Existing CPU suite: 37 passed, zero failures at grid 128. Existing GPU brush regression: two passed, zero failures ([log](interaction-existing-brush.log)). Headless editor import completed without parser errors. Visible GPU acceptance: **19 checks passed, zero failures at 128³** on Apple M5 Pro / Metal, including real camera targeting on all three axes, connected radius-zero strokes, wall preservation for strokes and regions, exact-byte brush/region undo, pending gesture metadata stability, non-destructive section toggling, material simulation, live painting, and return-to-build restoration. See [GPU log](interaction-gpu.log), [front section](interaction-front.png), and [angled section](interaction-angle.png). The brush-input checks invoke the editor event handler and project cells through the real camera; they are automated component checks, not an end-to-end human mouse usability test.

```sh
godot --headless --path . -s res://tests/discovery/interaction_unit.gd
godot --headless --path . -s res://tests/unit/run_unit.gd -- grid=128
godot --path . --resolution 1600x900 --always-on-top --disable-vsync -s res://tests/discovery/interaction_gpu.gd -- grid=128
```

## Proposed shared interface

- `PickRequest { ray, mode: plane|surface, plane_axis, plane_cell, visible_section, expected_generation }` produces `{ cell, normal, hit_material, generation }`. Surface picking must query authoritative voxel occupancy, not reconstructed liquid/refraction depth. GPU picking can be asynchronous; stale generations must be rejected or explicitly reconciled.
- `BeginEdit { transaction_id, authored|live, mask, target_generation }`, ordered `Stroke`/`Region` commands and `CommitEdit`/`CancelEdit`. Masks belong to the simulation edit kernel so occupied-cell preservation does not depend on stale CPU mirrors.
- `EditResult { transaction_id, changed_bounds, new_generation, undo_delta }` should contain pre/post changed cells or reversible authored operations. The renderer consumes dirty bounds once per committed batch. No full-volume CPU readback in ordinary painting.
- `Selection { inclusive_min, exclusive_max }` remains independent of renderer geometry, stores dimensions explicitly and later supports move/copy/rotate, named masks, coordinate entry and manipulator handles.
- `ViewSection { axis, maximum_cell, enabled }` is a view property shared by opaque, volume, grains, droplets, leaves, FX and picking. It does not edit simulation matter. The current prototype clips sprite instances by center, so quads touching the plane may extend slightly across it; a production implementation should clip per fragment in world space.
- `AuthoredRevision` versus `SimulationSnapshot`: return-to-build restores the former; a future full rewind needs all simulation fields and random/tick state in the latter. Undoing a live reaction by overwriting old voxels is not a valid generic undo model.

## Limits and next discriminating experiment

This is a runnable discovery slice, not the overhaul or a finished editor. It has no surface picking, drag handles, orthographic render support, saved worlds, redo, terrain sculpting, shaped/noise brushes, continuous timed emission while the cursor is stationary, transform/copy tools or persistent command log. A held stationary brush emits once; moving creates a geometric stroke. A future emission tool needs a time-based material rate independent of frame rate.

The section preserves lighting from hidden matter and uses existing smoothed density fields across the cut, so the cut is an inspection aid rather than a polished physical section surface. It hides the positive side regardless of camera orientation. The renderer still has the audit's material/readability shortcomings. No claim of production framerate or human usability validation is made from automated checks.

The next interaction experiment should compare surface-following paint and a fixed workplane on the same task: draw a container, fill it without breaking walls, inspect the interior, run, and return to build. Evaluate novices with only palette/radius/play visible initially; reveal region/coordinates when requested. Keep the full physical ambition, but use this workflow to establish reliable fundamentals before expanding the editor feature count.
