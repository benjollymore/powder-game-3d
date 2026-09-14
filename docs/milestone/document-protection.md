# Protecting unsaved constructions

The audit reproduced three destructive user paths: Reset container, Empty build, and a valid Open replaced authored material and cleared both history stacks, so subsequent Undo could not recover the previous construction. Their labels mentioned discarding edits, but they offered no opportunity to save or cancel. The editor also left Godot's automatic window-close behavior enabled. A separate save race left a plain “Saved build” message after an earlier snapshot finished while newer paint already existed. The [pre-change probe](document-protection-evidence/before-fix.log) reproduced all six conditions; its [source](document-protection-evidence/before-fix-probe.gd.txt) runs against parent commit `f4b7a23`.

The editor now shows an authored filename and unsaved status beside Save/Open. User Reset, Empty, valid Open, and normal window close share a **Save build / Discard / Cancel** choice when authored changes are unsaved. Cancel is initially focused. The choice waits for outstanding authored capture/file work. Failed or canceled Save keeps the construction and cancels the pending destructive action. Clean templates and saved constructions proceed directly. Build/Test/Return remain immediate, and live experiment changes do not dirty the authored construction.

`authored_document.gd` tracks a monotonically assigned authored checkpoint, its saved checkpoint, document generation, and the last successfully saved/opened file path. Regional history carries the two checkpoint IDs, so Undo/Redo to the saved checkpoint restores the clean indication. Return preserves these IDs despite the simulation epoch advancing. A clean no-op paint uses the existing bounded regional comparison and does not create a false dirty checkpoint. A failed history capture conservatively marks the construction unsaved because a mutation may already have happened.

`document_guard.gd` owns one pending destructive user intent. The low-level validated `replace_authored` API remains available for fixtures, file application, and internal resets. Save records the checkpoint/generation captured before readback; disk completion only marks that exact snapshot saved. Successful Save cannot authorize a pending replacement if a newer checkpoint, active stroke, pending capture, world epoch, or document generation intervened. The action is canceled instead. A Save that completes after a different document was installed cannot rename or mark that new document saved.

Open validates the selected file before asking to replace dirty work, and retains its existing revision/phase guard. If the user chooses Save first, Open reloads the **originally selected Open path** after the save succeeds. This avoids applying stale cached contents when Save overwrote that same file, and prevents Save As from redirecting the pending Open to the new save destination.

The guard disables `SceneTree.auto_accept_quit` for its lifetime and handles the root window's `close_requested` signal, restoring the previous policy on teardown. This follows [Godot's documented quit-request interception](https://docs.godotengine.org/en/4.4/tutorials/inputs/handling_quit_requests.html), exercised here on Godot 4.6.3. It covers normal application close; there is no autosave, crash recovery, OS shutdown interception, or forced-termination protection in this change.

## Verification

The GPU harness keeps the real editor and TimeController loops enabled, uses parsed canvas/button/key events and synchronized cursor position, reads complete packed-world bytes as a test oracle, and uses the real threaded archive jobs. Confirmation-dialog Cancel/Discard/Save and Escape are exercised through actual embedded GUI routing. Native file chooser results and cancellation are injected at FileDialog signals; this does not claim physical native-dialog or trackpad testing. Root `close_requested` is emitted directly, with Cancel first and explicit Discard closing the test application at the end; the user's OS session is never shut down.

Godot 4.6.3 / Metal / Apple M5 Pro, 1280×800:

| Validation | Result |
| --- | --- |
| Real editor protection at 128³ | [32/32](document-protection-evidence/gpu128-final.log) |
| Real editor protection at 256³ | [32/32](document-protection-evidence/gpu256-final.log) |
| Document identity and failure/continuation CPU checks | [21/21](document-protection-evidence/authored_document.log) |
| Existing queued editor actions | [14/14](document-protection-evidence/editor_actions_gpu.log) |
| Existing archive GPU lifecycle | [16/16](document-protection-evidence/archive_editor_gpu.log) |
| Existing active-process workflow | [24/24](document-protection-evidence/editor_workflow_gpu.log) |
| Pending authored input / exact regional Redo | [28/28](document-protection-evidence/pending_paint_gpu.log), [22/22](document-protection-evidence/editor_redo_gpu.log) |
| Existing history / archive / keyboard / paint CPU checks | [19/19](document-protection-evidence/history_guards.log), [7/7](document-protection-evidence/archive_panel.log), [8/8](document-protection-evidence/editor_keyboard.log), [9/9](document-protection-evidence/paint_tools.log) |

The [256³ close confirmation capture](document-protection-evidence/unsaved-close256.png) shows the filename, unsaved state, and all three choices at laptop resolution. Exact byte comparisons cover cancellation and recovery, saved-file contents, Undo/Redo-to-saved, a clean ONLY_AIR no-op, Test/Return separation, real disk failure, an in-flight newer stroke after Save capture, stale Open, same-file Open→Save, and Save As while Open is pending. Both final test applications closed cleanly through the guarded normal-close path after explicit Discard.

Existing queued Reset tests now explicitly choose Discard, rather than assuming silent replacement. The guard is not bypassed for ordinary UI tests. During harness development, its first UI attempt scrolled before expanded tools finished layout; awaiting that layout fixed two missed test clicks. A test-only coroutine left suspended across final quit was also removed. Neither issue remains in the final runs; original development logs remain in `/tmp/editor-document-protection-validation` for review.

```sh
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/document_protection_gpu.gd -- grid=128 output_dir=/tmp/editor-document-protection-128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/document_protection_gpu.gd -- grid=256 output_dir=/tmp/editor-document-protection-256
godot --headless --path . -s res://tests/milestone/authored_document.gd -- grid=128
```

No archive-format or solver change is included. Normal strokes retain bounded regional history; file Save/Open may still read an entire authored volume deliberately, and Save-before-Open can perform one additional explicit file read. The dirty marker tracks known authored checkpoint identity rather than hashing the whole world every frame: manually reconstructing identical material is conservatively treated as an edit. The protection dialog is only for authored work, not unsaved runtime experiment evolution.
