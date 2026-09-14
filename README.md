# Powder Game 3D

A 3D falling-sand physics sandbox in the spirit of Powder Game / The Powder Toy,
built with Godot 4 as a learning project. Fly anywhere around a glass box,
freeze time, step it, slow it down, paint elements in, and let it go.

World size is the project setting `powder/sim/grid_size` (256 by default, a
multiple of 8; every voxel is one centimetre so the box is 2.56 m) and can be
overridden per run with `-- grid=128`, which is what the tests use.

Requires **Godot 4.6.3** (4.7.x hangs at startup on Apple M4/M5 + macOS 26,
see godotengine/godot#123479). Open `project.godot` in the editor and press
Play, or run `godot --path .` from the repo root. Add `-- scenario="Dam break"`
to start in a preset.

## Controls

| Key | Action |
|---|---|
| Left mouse (hold) | Paint with the brush at the sphere cursor |
| 1–9 | Pick element (wall, sand, water, steam, fire, plant, oil, smoke, wood) |
| X | Toggle erase |
| [ / ] | Brush radius |
| Shift + scroll | Move the brush cursor along the view ray |
| Right mouse (hold) + move | Look |
| W A S D / Q E | Fly / down / up |
| Shift | Sprint |
| Scroll | Fly speed (fly mode) / distance (orbit mode) |
| O | Toggle orbit mode around the box |
| F | Frame the box |
| T | Toggle tilt-shift depth of field |
| Space | Pause / resume time |
| N | Advance one tick while paused |
| , / . | Halve / double time scale |
| 0 / Backslash | Freeze / real time |
| C | Clear the world |
| R | Reload the current scenario (pick one in the top bar) |
| F3 | Toggle the stats overlay |
| F5 | Hot-reload the simulation compute shader from disk |
| F9 | Print a per-element voxel count to the console |

## Tests

```sh
# After editing a compute shader (.glsl) or adding a class_name script, reimport
# first: command-line runs use the imported SPIR-V and do not rebuild it.
godot --headless --path . --import
# CPU-only unit tests (headless)
godot --headless --path . -s res://tests/unit/run_unit.gd -- grid=128
# GPU simulation tests (need a window: headless has no RenderingDevice)
godot --path . --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd -- grid=128
```

See `docs/` for the voxel format and simulation rules.
