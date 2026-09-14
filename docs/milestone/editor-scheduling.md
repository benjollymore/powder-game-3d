# Normal editor scheduling measurements

This complements the short fixed-tick [editor benchmark](editor-performance.md). The editor and TimeController run their ordinary process loops, with VSync enabled and live material-surface previews. No fixed number of simulation ticks is forced per frame. Each measured run lasts 20 wall-clock seconds after warmup, with actual rendered-frame boundaries, achieved simulation tick rate, and exact authored Return checked.

Conditions: Godot 4.6.3, Metal / Apple M5 Pro, 1600×900 window, default 0.75 rendering scale, default presentation, default scheduler settings. The machine's visible refresh is approximately 120 Hz. The surface-preview workload explicitly disables cutaway and places the cursor over the world, then restores the original OS cursor on completion. Button holds are not synthesized in this benchmark. The separate [active-input workflow](editor-workflow.md) covers painting and GUI actions.

| Grid / fixture | Rendered frames | Mean / p95 / max frame interval | Achieved / target ticks per second | Frames at scheduler cap |
|---|---:|---|---|---:|
| 128³ / default bowl, surface hover | 2391 | 8.365 / 8.880 / 17.019 ms | 179.896 / 180 | 0 |
| 256³ / default bowl, surface hover | 2395 | 8.354 / 8.546 / 16.933 ms | 119.950 / 120 | 0 |

The 128³ run issued **388 preview requests**, with a valid target on every measured frame. Return restored the exact authored packed bytes. Renderer-reported video memory stayed at **166,920,192 bytes** throughout the measured windows. [Manifest and results](soak-surface128/results.json), [raw log](soak-surface128/grid-128-bowl/run.log), [authored view](soak-surface128/grid-128-bowl/authored.png), [experiment view](soak-surface128/grid-128-bowl/experiment.png).

The 256³ run issued **400 preview requests**, again with a valid target on every measured frame and exact authored Return. Renderer-reported video memory remained **378,404,864 bytes**. [256³ results](soak-surface256/results.json), [raw log](soak-surface256/grid-256-bowl/run.log).

This small fixture supports responsive ordinary scheduling at both sizes under these conditions. It does not establish dense-world or long-session performance. VSync hides unused frame-time headroom, so these intervals are not GPU execution times. Larger fixtures are in progress.

## Measurement boundaries

- The counter records requested simulation ticks. An ordered full readback after timing drains the physical work and verifies Return; it is outside the frame-interval sample.
- The timer, rendered frames and tick counter are sampled over the same interval. Configuration hashing happens before warmup, avoiding a false first-frame catch-up burst from the benchmark itself.
- CPU memory is Godot's reported static allocation, not process RSS. It includes retained test snapshots, the growing sample array and telemetry dictionaries. Renderer memory comes from engine counters; it is not a driver allocation audit.
- A frame reaching the scheduler's maximum tick count is reported as a cap frame. That alone does not prove ticks were dropped; achieved ticks per second gives the useful rate comparison.
- Across grid sizes, scenarios have the same normalized layout but cells remain one centimetre wide. Physical box size and material quantity therefore change, and default tick rates differ. These are product workload comparisons, not equal physical experiments.
- Early two-second surface probes correctly produced invalid add targets on the default section cap. Their rejection exposed a separate editor usability issue. This valid-surface workload turns cutaway off explicitly; it does not relabel those rejected targets as successful picks.
- The initial authored PNGs in these first two runs precede the first draw after changing target mode and cutaway. They show the preceding authored view; experiment captures show the active workload view. The harness now waits for a post-configuration draw before capturing, separately from all timing samples.

```sh
godot --headless --path . --import
python3 tools/milestone/run_editor_soak.py --grids 128 --scenarios bowl --seconds 20 --surface-hover
# Ordinary cutaway scenarios, still with normal scheduling:
python3 tools/milestone/run_editor_soak.py --grids 128 256 --scenarios 'Dam break' 'Forest fire' --seconds 20
```

The runner launches one visible process at a time, enforces a watchdog, saves raw logs/results/captures, and refuses a nonempty evidence directory. Its default output path includes the current UTC timestamp. Keep other GPU tests closed while it runs.
