# Pointer events crossing editor controls

A fast held pointer could enter and leave the toolbar between rendered frames. GUI controls consumed the middle motion, while the editor only broke its stroke in `_process`. The next scene motion therefore connected to the previous scene point, inventing a straight paint segment that the pointer never traversed. A live source could also remain armed until the next process frame, allowing an already-queued simulation tick to inject material after the pointer had entered the toolbar.

The editor now breaks its workplane and surface segment and cancels the live source in `_input` as soon as a mouse-motion event enters the toolbar, before GUI dispatch consumes the event. Existing per-frame hover handling remains. Returning to the scene while held continues the same authored transaction from a fresh endpoint. Navigation and material metadata are unchanged.

`editor_gui_crossing_gpu.gd` runs the production editor and time loops with parsed engine mouse events and synchronized OS cursor position. It sends scene → toolbar → scene motion and release without yielding a process frame between events. Complete packed-world comparisons identify every changed voxel, then verify exact Undo and Redo. A separate paused-Test case enters the toolbar and explicitly queues one authoritative tick before a process frame can notice the hover; that tick must add no stale Sand.

At 128³ on Godot 4.6.3 / Metal / Apple M5 Pro:

| Case | Before fix | After fix |
| --- | --- | --- |
| Workplane crossing | 17 changed cells | Exactly 2 intended endpoints |
| Surface crossing | 33 changed cells | Exactly 2 intended surface deposits |
| Live source entering toolbar | Remains armed; stale material injected | Canceled immediately; packed state unchanged |
| Exact Undo/Redo | Preserves the incorrectly authored stroke | Preserves only the intended separated deposits |

The [fixed run](gui-crossing-evidence/gpu128.log) passed **13/13 checks**. Running the same behavioral harness against the pre-fix source reproduced **4 failures**, recorded in the [counterfactual log](gui-crossing-evidence/before-fix128.log). The seven-line production fix was restored immediately after that counterfactual run. This is injected engine-input evidence, not physical trackpad validation.

```sh
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/editor_gui_crossing_gpu.gd -- grid=128 output_dir=/tmp/editor-gui-crossing
```

The same source review separately reproduced a dropped primary press during an asynchronous history capture: Input remains held after the capture completes, but no new paint gesture starts. That requires a bounded pending authored gesture retaining its metadata, curve and release; it is a separate change so its phase/world/modal/navigation cancellation policy can be tested independently.

The separate dropped-press issue is now handled by [bounded pending authored paint](pending-paint.md), with independent asynchronous history and lifecycle regressions.
