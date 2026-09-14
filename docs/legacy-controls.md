# Original sandbox controls

Launch the original scenario viewer explicitly:

```sh
godot --path . res://scenes/main.tscn -- scenario="Dam break"
```


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

