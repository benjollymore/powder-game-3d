# Editing fundamentals checkpoint 1

Ordinary build strokes now capture exact packed bytes only from first-touched 8³ GPU tiles. A transaction copies each tile before its first mutation, then edits immediately; asynchronous readback completes the undo entry after the gesture closes. Repeated and overlapping brush/region commands retain the same original before-image. Undo restores these regions without resetting unrelated simulation fields. There is no full-volume CPU snapshot at the beginning of a stroke.

The measured tiny stroke crossing two tiles transfers **4096 bytes** at both 128³ and 256³. The corresponding complete voxel volumes are 8,388,608 and 67,108,864 bytes. This is a concrete transfer reduction, not a framerate claim. Root integration will measure visible painting latency and frame distributions. Large region commands still enumerate and copy their touched tiles; GPU storage and derived renderer updates remain dense.

Transactions have a 16 MiB before-image cap and build history retains at most 128 MiB of voxel data, excluding dictionary overhead and in-flight staging copies. If a gesture exceeds its cap, the accepted prefix remains undoable and the editor says the remaining paint was skipped. An oversized region is rejected before that region changes any material. Failed/truncated readback never becomes a valid undo entry. The editor clears its history and explains the failure rather than advertising unavailable undo.

World resets advance `edit_epoch`; stale transaction commands submitted after a reset and stale undo records are rejected. `edit_revision` separately counts ordered edit submissions. Return-to-build still deliberately retains one complete authored voxel snapshot, restores it with the existing upload API and rebinds existing authored history to the new reset epoch. The simulation worker owns the centralized solver/presentation reset behind upload. This is an authored reset, not arbitrary runtime rewind.

Live held painting emits 24 additional stamps per second at a stationary valid target, independently of rendered-frame count. The initial press and connected geometric motion trail retain their existing placement behavior. A resumed/stalled frame emits at most four catch-up stamps and retains no unbounded backlog. Paused additive construction does not waste repeated dispatches stamping the same unchanged cell. Navigation and invalid/hidden targets reset the emission accumulator.

Validation before the surface-picking checkpoint:

- Regional undo GPU: 12 original checks at 128³, then 17 checks at 256³ including reset-epoch rejection, 16 MiB cap behavior and exact prefix undo. All passed. Exact equality compares every packed voxel byte, including seed/amount.
- Existing integrated interaction GPU: 19 passed, including wall preservation, brush/region undo, live paint and return-to-build.
- Existing trackpad GPU: 27 passed; native gesture-routing headless checks: 10 passed.
- Held-emission CPU traces: nine passed, including 240 stamps over ten seconds at 15, 30, 60, 120 and 240 FPS, one-minute stall cap and accumulator reset.

```sh
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/regional_undo_gpu.gd -- grid=256
godot --headless --path . -s res://tests/milestone/editing_unit.gd
```

New public transaction APIs on `VoxelSim`: `begin_edit_transaction(callback) -> id`, `record_stroke(id, centers, radius, element, mode, seed)`, `record_region(id, lo, hi, element)`, `finish_edit_transaction(id)` and `restore_edit_transaction(result) -> bool`. Region upper bounds are exclusive. Completion is observable through `edit_transaction_ready` and editor `edit_completed`, with result fields `id`, `epoch`, `regions`, `bytes`, `valid`, and `error`. Completion means before-image transfer is available, not a renderer benchmark. `capturing` remains true until the active authored gesture is sealed and its history data is ready.

Still in progress: authoritative surface picking and intent/generation rejection. Existing workplane and native gesture routing remain intact. Persistence UI and matched performance measurement are coordinated separately.
