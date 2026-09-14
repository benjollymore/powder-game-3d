# Painting while history finishes

A primary press arriving between an authored stroke's release and its asynchronous history callback was dropped. The same happened while Undo or Redo captured its inverse. Continuing to hold the button did not recover the gesture: the production Input singleton remained pressed, but the editor had never entered painting. The source review reproduced this with active editor processing before this change.

The editor now retains one waiting **Build** gesture while an authored or inverse history capture finishes. It records input-time workplane cells or immutable surface rays, the material/radius/erase settings, section geometry, and release state. Replay begins only after the preceding history operation succeeds. A held gesture continues normally; a released gesture completes as its own regional transaction. Surface rays are resolved against the ordered authoritative GPU state, with the existing ONLY_AIR and section contracts.

This is a bounded input buffer, not another world snapshot. It holds at most **256 distinct samples in one gesture**. Repeated stationary samples do not consume that budget. Toolbar crossings preserve segment gaps. An overflowing path seals its retained prefix and displays an explanation; an additional waiting press is rejected with feedback while the first waiting stroke remains intact. The existing 16 MiB regional transaction limit and shared 128 MiB Undo/Redo budget still apply. Normal authored strokes continue to use regional before-images.

Undo cancels the newest waiting gesture without also deleting the previous applied edit. A second Undo reaches the applied history normally. Navigation, view changes, region mode, phase/reset intent, modal entry, teardown, epoch changes, and failed history capture discard pending placement. Material/radius changes seal the frozen stroke without rewriting its settings. Run's full authored snapshot capture never accepts waiting Build paint, and Test keeps its fixed-tick source path.

Pending replay is started inside the history-completion callback, before completion signals are emitted. This avoids an idle gap where an asynchronous Open could replace the construction between the preceding edit and the accepted waiting gesture. Archive dialog requests and actual modal entry also cancel waiting placement. File format and solver APIs are unchanged.

## Evidence

Godot 4.6.3, Metal, Apple M5 Pro; 1280×800. Both production editor and TimeController process loops stay enabled. The test sends parsed engine mouse/key events, synchronizes the real OS cursor with the viewport, and restores it afterward. This is **not physical trackpad validation**. Fixture setup uses editor APIs; native modal entry is invoked directly rather than opening a real native file dialog. Save/Open race coverage uses the actual threaded archive API. No history callback is delayed or mocked in the GPU harness.

| Validation | Result |
| --- | --- |
| Pending input with actual history at 128³ | [28/28](pending-paint-evidence/gpu128.log) |
| Pending input with actual history at 256³ | [28/28](pending-paint-evidence/gpu256.log) |
| Existing queued editor actions | [13/13](pending-paint-evidence/editor_actions_gpu.log) |
| Existing archive GPU lifecycle | [16/16](pending-paint-evidence/archive_editor_gpu.log) |
| Existing active-process editor workflow | [24/24](pending-paint-evidence/editor_workflow_gpu.log) |
| Existing toolbar-crossing GPU behavior | [13/13](pending-paint-evidence/editor_gui_crossing_gpu.log) |
| Pending buffer CPU / history failure guards | [7/7](pending-paint-evidence/pending_gesture.log), [19/19](pending-paint-evidence/history_guards.log) |
| Archive / keyboard / paint-tool CPU regressions | [7/7](pending-paint-evidence/archive_panel.log), [8/8](pending-paint-evidence/editor_keyboard.log), [9/9](pending-paint-evidence/paint_tools.log) |

Complete packed-world comparisons prove that a rapidly released L-shaped plane stroke changes precisely its two legs: 34 total cells including the separate first dot at 128³, and 66 at 256³. Later Water/radius-one selection cannot change that queued Sand/radius-zero stroke. Its Undo restores the exact first-dot bytes; Redo restores exact amounts and seeds. The held-Undo and short-click-Redo cases preserve separate history entries. The equivalent surface curve changes only the expected cells outside its flat wall and preserves every original wall. The suite also checks a toolbar gap, explicit one-gesture overflow, Undo cancellation, navigation/modal/world/Run cancellation, and Open completion after a newer Undo plus waiting paint.

```sh
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/pending_paint_gpu.gd -- grid=128 output_dir=/tmp/editor-pending-paint-128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/pending_paint_gpu.gd -- grid=256 output_dir=/tmp/editor-pending-paint-256
godot --headless --path . -s res://tests/milestone/pending_gesture.gd
godot --headless --path . -s res://tests/milestone/history_guards.gd
```

Raw logs preserve their original test labels; “physical Input hold” in the original two GPU logs refers to `Input.is_mouse_button_pressed` driven by parsed events, not real hardware input. The harness label now says “parsed Input hold.” These tests establish correctness under deliberately adjacent input/capture events, not a measured end-to-end input latency or unlimited buffering guarantee. An unusually long capture can still exceed the explicit sample/gesture bounds; that loss is reported rather than silently inventing geometry or growing memory indefinitely.
