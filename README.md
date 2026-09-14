# Powder Game 3D

A 3D material sandbox inspired by The Powder Toy. The current milestone focuses on a dependable paint-and-sim loop: build on an exact workplane or material surface, inspect a section, run the experiment, and return to the authored construction.

This is still an alpha. The current cellular solver does not yet provide general material momentum, thermodynamics or moving rigid assemblies. See the [architecture assessment](docs/milestone/architecture-feasibility.md) for the remaining physical work.

## Run

Tested with **Godot 4.6.3** on macOS / Metal. Open `project.godot` and press Play, or run:

```sh
godot --headless --path . --import
godot --path .
```

The session uses 256³ cells by default; each cell is one centimetre. For a smaller session with more performance headroom, run `godot --path . -- grid=128`. The original scenario viewer remains available with its [original controls](docs/legacy-controls.md).

## Paint and play

Start in Build. Drag to add material into empty space; existing walls are preserved. Choose a workplane for exact depth or Material surface to place against visible material. Toggle erase to remove material. Section view hides the positive side of the selected plane without deleting it.

Run experiment saves the authored construction and starts physics. Painting during Run affects that experiment. Return to build restores the saved construction and its undo history. Save build writes the authored construction even while the experiment is running; Open build starts a fresh paused Build. Files must match the current session's grid size.

Pause/Resume and Single step let you inspect a live experiment without restoring the build. A released live paint click is applied on the next simulation tick; paused Test does not advance or inject material until resumed or stepped. Build painting remains immediate.

| Control | Action |
|---|---|
| Left drag | Paint or erase |
| Two-finger swipe | Orbit |
| Shift + two-finger swipe | Pan |
| Pinch | Zoom |
| Option + drag | Orbit fallback |
| Option + Shift + drag | Pan fallback |
| Right drag / wheel | Orbit / zoom |
| Shift + wheel; plane −/+ buttons | Move the workplane |
| [ / ] | Brush radius |
| X | Paint / erase |
| Ctrl/Cmd Z | Undo authored edit |
| Ctrl/Cmd Shift Z | Redo authored edit |
| Space | Run / return to build |
| P / N, during Test | Pause/resume / single step |
| V / F | Center on the workplane / angled view |
| B | Optional two-corner region tool |

Construction tools include region filling and fresh empty/container builds. Undo and Redo share a bounded regional history; a changed new edit clears Redo. Live edits are discarded on Return; authored history is not a runtime rewind.

## Verification

GPU checks need a visible window. On macOS, keep one GPU test running at a time and use `--always-on-top`; an occluded process loop is not reliable rendering evidence.

```sh
godot --headless --path . --import
godot --headless --path . -s res://tests/unit/run_unit.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tests/gpu/run_gpu_tests.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/archive_editor_gpu.gd -- grid=128
# Bounded suites with logs and explicit error checking (one GPU process at a time)
python3 tools/milestone/verify.py
python3 tools/milestone/verify.py --gpu
```

See [milestone status](docs/milestone/status.md), [editor measurements](docs/milestone/editor-performance.md), [editing contracts](docs/milestone/editing.md), and [authored files](docs/milestone/authored-archives.md) for evidence and limitations.
