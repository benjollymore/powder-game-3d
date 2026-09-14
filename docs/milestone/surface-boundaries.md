# Surface ray boundary review

Source review found that the voxel DDA advanced one axis at a time when two boundary times tied. A diagonal ray could therefore inspect a voxel that it touched only along an edge or corner, with zero travel distance through its interior. If that voxel contained a wall, it incorrectly intercepted the ray before a later true hit.

The picker now advances all simultaneous boundary crossings together (within 1e-6 voxel-distance units), retaining the first tied axis as a deterministic placement normal. This avoids the false occluder without changing ordinary face crossings. At an exact corner there is no unique face normal; the chosen axis is a stable editor convention. Add remains non-destructive through ONLY_AIR. A ray starting inside solid material may erase its hit cell, but cannot invent an outside face for adding.

The expanded surface harness passed **36 GPU checks at 128³**, including ten new checks for all six axis directions, camera-inside-solid add/erase, diagonal edge-only contact, and an away-facing ray. Existing masks, section boundaries, local exact undo and stale-preview checks passed. Integrated surface emission also produced exactly 24 grains over 120 ticks, with equal complete voxel bytes for tick batches 1, 3 and 7.

```sh
godot --headless --path . --editor --import
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/surface_pick_gpu.gd -- grid=128
```

The log from this run is `/tmp/surface-boundaries128.log`. These are deterministic fixture checks, not an exhaustive proof over every floating-point grazing ray. Surface Build transactions still use the documented 64-byte GPU readback fence to determine exact undo tiles, while live stamps repick and mutate atomically on the GPU.
