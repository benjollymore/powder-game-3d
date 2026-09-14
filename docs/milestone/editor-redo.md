# Bounded authored Undo and Redo

Build exposes adjacent Undo build and Redo build buttons, with Ctrl/Cmd–Z and Ctrl/Cmd–Shift–Z shortcuts. Numeric text keeps its own editing shortcuts. Test disables authored history actions; returning to Build restores the authored state with both history directions intact. Empty, Reset container and Open clear both stacks. Region fills, workplane brushes, surface brushes and erasing use the same packed regional history.

A history action first captures the current contents of exactly the original transaction's unique 8³ tiles. One regional GPU staging buffer holds that inverse. The main-thread callback validates byte lengths, tile identity/order, reset epoch, authored revision and simulation tick before submitting restoration. Until that succeeds, the original history entry remains on its source stack. Invalid or failed capture makes no restoration submission and reports the error; a world replacement invalidates its old history. The validated inverse moves to the opposite stack only after restoration is accepted. Restoration refreshes derived rendering through the existing edit path and does not reset unrelated solver history.

The public additions are `reverse_edit_transaction(record, callback) -> bool` and `inspect_edit_transaction(record, callback) -> bool`. The first returns the inverse record with `applied`; the second returns a read-only `changed` result. Both operate on paused authored state. Acceptance is asynchronous: `capturing` and `edit_completed` remain the editor's completion contract. Existing test callers that used to read immediately after Undo now wait for `capturing` to finish. This is required because restoration follows successful inverse capture, rather than preceding it.

A changed new authored edit clears Redo. When a Redo chain exists, the editor performs one additional bounded regional comparison after a new gesture to distinguish real changes from occupied ONLY_AIR stamps. Exact no-ops retain Redo and add no new Undo entry. A missed gesture has no captured regions and needs no comparison. If that comparison fails after a new mutation, the conservative fallback clears Redo, retains the new valid Undo and explains the failure. Ordinary new strokes without Redo retain the existing single before-image transfer.

Both stacks share one **128 MiB retained packed-byte cap**. Crossing the cap evicts the oldest past edit first; if only future history remains, it evicts the farthest future, keeping the next Redo contiguous. Moving an entry between stacks does not double its retained byte count. The existing **16 MiB per-transaction cap** still rejects an oversized remaining command before it changes material; its accepted prefix supports both Undo and Redo. Dictionary metadata, in-flight regional GPU/CPU transfer copies, the current transaction, and the deliberate full Build snapshot used by Run are outside the retained-history cap. An inverse temporarily coexists with its source before validation; this is a bounded transient allocation, not a promise that total process memory stays below 128 MiB.

No ordinary history action reads the whole voxel texture. The tested two-tile edit and each inverse transfer 4096 bytes at both 128³ and 256³, compared with full packed volumes of 8,388,608 and 67,108,864 bytes. On Godot 4.6.3 / Metal / Apple M5 Pro, nine measured action completions at 128³ took 3.90–23.94 ms. The final 256³ run measured eleven actions, including two smaller accepted-prefix actions, at 3.57–18.42 ms. These are small scripted samples from calling the action through regional-capture completion and one frame wait, not renderer GPU times, latency percentiles or input-to-photon measurements.

Validation completed with no failures:

- `history_guards.gd`: 18 headless checks covering a shared cap with both stacks, contiguous eviction, exact-cap boundary, malformed/duplicate/unaligned/truncated tiles, wrong-region replies, readback failure, stale revision/tick/epoch, no-op comparison and retention of the only recoverable Undo on failed inverse capture.
- `editor_redo_gpu.gd`: 22 checks at 128³ and 25 at 256³. Exact full-world byte comparisons verify mixed paint/region/erase, repeated reverse operations, wall integrity, no-op and changed branches, both stacks across actual Run/Return, epoch reset during capture, queued Empty, and accepted-prefix Redo after cap rejection.
- Existing regressions: editor actions 13, interaction 20, active-frame editor workflow 24, regional undo/cap 17 at 256³, keyboard routing 8, paint tools 9, Test phase controls 9, and native gesture routing 10.
- Headless editor import completed with no parser errors. It regenerated several pre-existing missing UID files; unrelated generated files are excluded from this change.

The coordinator independently reran Redo at both grids, the active editor workflow and queued-action guards after integration: **22 + 25 + 24 + 13 GPU checks passed**. [Integrated GPU manifest](redo-integrated/gpu-results-93dd96d6.json). The **18 history guards and eight keyboard checks** also passed. [Integrated CPU manifest](redo-integrated/cpu-results-f934b109.json). Raw logs accompany each manifest; these are separate runs from the worker's timing samples above.

```sh
godot --headless --path . -s res://tests/milestone/history_guards.gd
godot --headless --path . -s res://tests/milestone/editor_keyboard.gd
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/editor_redo_gpu.gd -- grid=128
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/editor_redo_gpu.gd -- grid=256
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/editor_workflow_gpu.gd -- grid=128
```

The Redo GPU harness invokes production editor actions deterministically with per-frame painting disabled. The separate workflow regression leaves both editor and time loops active and routes parsed engine events with synchronized OS cursor position; its injected events do not constitute physical Mac trackpad validation. New regression screenshots and fixtures go under `/tmp`, preserving historical discovery evidence. This work does not add runtime rewind, save history into the archive, or change archive format.
