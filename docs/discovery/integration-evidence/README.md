# Independent combined-branch verification

Coordinator run on 14 September 2026, Apple M5 Pro, Godot 4.6.3/Metal. Tested source tree: `59a155a` on `discovery/review`, combining simulation `d36d1e2`, rendering `8a43efd` and interaction `59a155a`. Subsequent integration changes are documentation/evidence and generated script UIDs only.

| Check | Result | Evidence |
|---|---|---|
| Headless import | Completed without parser errors | [import.log](import.log) |
| Existing CPU | 37 checks, zero failures | [unit.log](unit.log) |
| Interaction geometry/time | 20 checks, zero failures | [interaction-unit.log](interaction-unit.log) |
| Existing GPU, 128³ | 74 checks, zero failures | [gpu128.log](gpu128.log) |
| Interaction GPU, 128³ | 19 checks, zero failures, including two screenshot saves | [interaction128.log](interaction128.log) |
| Coalescing replay, 256³ | Ten pairs preserve full voxel/air hashes; exits zero | [simulation256.log](simulation256.log) |
| Tick-batching diagnostic | Divergence independently reproduced with air enabled; equality with air disabled | Same simulation log |
| Frozen renderer, 256³ | Eight measurement phases, four captures, two unchanged-state hashes; exits zero | [rendering.log](rendering.log), [measurements](rendering/measurements.json) |

GPU processes ran sequentially with `--always-on-top --disable-vsync`; visible rendering/capture tests used 1600×900. Source review covered shared brush modes and dispatch barriers, construction snapshot/pending-stroke behavior, time input ownership, disabled-by-default section controls and required sprite representation, and the coalescing override. Captured editor and material images were visually inspected. This was not a manual desktop mouse usability test.

The shorter coalescing integration run uses `frames=30` (plus the existing 30-frame warmup), two ticks per frame, fixed seed and reversed repeat order. Painting means were 26.723 → 22.037 ms and 23.110 → 18.118 ms. Unchanged controls also varied substantially, so these are integration observations, not a replacement for the longer worker study or an isolated GPU-pass claim. All ten physical-state equivalence pairs passed. The known batch-invariance defect is reported diagnostically and is **not** fixed or counted as a passing invariance test.

The renderer integration rerun remained variable:

| Scene | Existing mean ms, repeats 1 / 2 | Clean mean ms, repeats 1 / 2 |
|---|---:|---:|
| Material lab | 5.63 / 6.10 | 5.59 / 3.16 |
| Dam break | 4.40 / 8.39 | 3.90 / 11.18 |

These results do not support a stable performance improvement. Timing uses application frame observations, not per-pass GPU timestamps. Both frozen-state hash checks passed. The renderer emitted `ObjectDB instances leaked at exit`; no runtime script/shader errors were logged. The coordinator's shorter simulation run did not emit that warning, although the worker's original run did. Resource lifecycle remains uninvestigated.

Original worker screenshots and measurements are preserved in their original locations. Integration captures live here: [front editor](interaction-front.png), [angled editor](interaction-angle.png), and [rendering captures](rendering/). The acceptance screenshot's displayed FPS includes expensive readbacks and CPU assertions and is not an editor performance benchmark. The HTML gallery is a local report with inspected image assets; browser interaction was not independently tested.

Reproduce from the review worktree, with GPU commands run serially:

```sh
godot --headless --path . --import
godot --headless --path . -s res://tests/unit/run_unit.gd -- grid=128
godot --headless --path . -s res://tests/discovery/interaction_unit.gd
godot --path . --always-on-top --disable-vsync -s res://tests/gpu/run_gpu_tests.gd -- grid=128
godot --path . --resolution 1600x900 --always-on-top --disable-vsync -s res://tests/discovery/interaction_gpu.gd -- grid=128
godot --path . --resolution 1600x900 --always-on-top --disable-vsync -s res://tools/discovery/simulation_bench.gd -- grid=256 frames=30
godot --path . --always-on-top --disable-vsync -s res://tools/discovery/rendering.gd -- batch=1
```

The capture harnesses write into their documented default evidence paths when rerun. Copy new outputs aside before restoring a historical evidence set if comparing runs.
