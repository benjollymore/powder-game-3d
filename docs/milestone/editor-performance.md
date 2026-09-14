# Integrated editor workload measurements

Measured on 2026-09-14, Godot 4.6.3 / Metal / Apple M5 Pro, one visible 1600×900 window, VSync disabled. The editor uses the corrected shaders and attached presentation/theme/archive modules. Each workload resets the same authored bowl, warms for 20 frames and measures 90 frames. Running workloads explicitly request two fixed ticks per rendered frame.

| Workload | 128³ mean / p95 ms | 256³ mean / p95 ms |
|---|---:|---:|
| paused | 2.26 / 7.50 | 2.40 / 7.28 |
| running | 3.40 / 8.43 | 10.86 / 11.67 |
| paused_paint | 2.49 / 6.10 | 4.59 / 8.04 |
| running_paint | 3.59 / 8.53 | 11.08 / 11.67 |
| surface_paint | 2.38 / 4.58 | 3.78 / 8.96 |

These short scripted workloads remain below 16.7 ms at the 95th percentile. Some 128³ samples exceed 20 ms; this is not a no-stutter claim. The two grid sizes have different configured physical tick durations and therefore do not represent equal elapsed physical time. They measure the cost of the stated two-tick submission workload.

## What was measured

`tools/milestone/editor_bench.gd` instantiates the actual editor scene and invokes its GPU editing backend. Samples end at `frame_post_draw`. The retained 1600×900 captures show the initial bowl, spread water and newly emitted sand, and the benchmark records drawn-frame counts and full voxel hashes. This guards against mistaking an occluded process loop for useful rendering.

The surface workload includes authoritative GPU ray resolution, its 64-byte synchronous fence and regional before-images. The workplane workload includes regional history. Holding the live source uses fixed-tick injection. Input is disabled and the editor process callback is disabled for this deterministic harness: these numbers are **not** physical trackpad/input-to-photon latency, automatic time-controller behavior, or a sustained thermal stress test. Pointer motion and gesture correctness are checked in separate input harnesses.

## History and limits

The 110-frame scripted workplane stroke retained 57,344 bytes at 128³ and 98,304 bytes at 256³. The surface stroke retained 102,400 and 223,232 bytes respectively. The history callback completed 1.15–1.44 ms after closing those 128³ strokes and 0.024–0.036 ms after closing the 256³ strokes; earlier tile transfers overlap the stroke, so this is only the remaining completion delay, not total transfer latency.

This bowl occupies a small fraction of the domain. Dense mixed-material scenarios, high simulation rates, large brushes and long sessions still need separate measurements. No comparison here establishes a percentage speedup over the old editor: the previous discovery benchmark used a different physical cadence and workload.

Run:

```sh
godot --path . --always-on-top --disable-vsync --resolution 1600x900 \
  -s res://tools/milestone/editor_bench.gd -- grid=128 frames=90
```

Repeat with `grid=256`. Raw logs and images are in `editor-evidence/`.
