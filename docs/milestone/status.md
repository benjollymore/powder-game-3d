# Autonomous milestone status

Updated 2026-09-14 21:59 UTC. Work continues until the user checks in; four hours is an estimate, not a deadline. Integration checkout: `powder-game-3d-discovery/fundamentals`, branch `milestone/fundamentals`. The original main checkout is preserved.

## Current result

The project now launches the paint editor. Build on an exact workplane or an authoritative material surface, undo regional authored edits, run/pause/step an experiment, and return to the authored construction. Save/Open uses a validated, compressed authored archive; a running experiment saves its original build. Common materials are exposed first, with region and section controls optional. Trackpad navigation has native gesture handling and Option-drag fallbacks.

The simulation advances air and held sources at authoritative tick cadence. Paused rebuilds preserve temporal state. Short released paint clicks survive until the next simulation tick. Render corrections cover rigid normals, section normals/depth, and per-fragment clipping of physical sprites. These are foundations for a usable alpha, not a claim of finished visual fidelity.

Recent lifecycle review fixed legacy shortcuts advancing time while a modal owned input, async Open missing a completed live gesture, and repeated queued Run clicks toggling straight back to Build. Current screenshots are in [editor-current](editor-current/); they are short presentation captures, not frame-time evidence.

Subsequent active-input testing fixed Space also activating a focused GUI button. The [complete workflow](editor-workflow.md) now exercises held painting, GUI controls, paused clicks and exact Return through ordinary editor processing. [Symmetric leaf origins](leaf-origin.md) are finite, and [liquid segments now close correctly](liquid-edge-noise.md) after delayed density exits. Both rendering fixes preserve physical bytes.

[Regional Redo](editor-redo.md) is integrated, with validated inverse capture, one shared past/future history budget, no-op branch preservation, and exact Run/Return behavior. The coordinator reran it at both grid sizes and preserved raw logs.

## Validation and performance

- A coordinator run of 15 GPU suites passed **484 checks**, including regional undo at 256³ and physical/render/input/archive suites at 128³. Seven CPU suites passed **94 checks**. [Combined evidence](verification.md) states the revision scope and later targeted checks.
- Latest targeted lifecycle/phase/preparation runs passed **16 + 13 + 8 + 12 + 4 GPU checks**. Gesture, paint-tool and phase CPU checks passed **10 + 9 + 9 checks**. Do not add these overlapping runs into a unique coverage total.
- Independently rerun thermal and PIC/APIC reference suites passed **22 tests**. These are isolated CPU references, not production solver capabilities.
- Short, visible editor measurements at 1600×900 found running-source mean/p95 **3.59/8.53 ms at 128³**, **11.08/11.67 ms at 256³**, at two ticks per measured frame. The small fixture, fixed workload and short duration limit generalization. [Measurement method and raw evidence](editor-performance.md).
- Render-preparation coalescing remains opt-in: it helps some repeated edit workloads but did not improve the already-combined held-source workload. An indirect physical-sprite prototype remains on its experiment branch: its clearest gain was about 0.4 ms at 256³ and it exposed a Godot command-buffer leak.
- Later integrated checks passed **203 leaf checks**, **102 liquid-path checks**, **61 section-depth checks**, and **24 full workflow checks**, with archive/action guards rerun. [Profiling and integration evidence](gpu-profiling.md). GPU timestamp reporting now explicitly reports unavailable data on the pinned Metal backend rather than zero pass cost.
- Twenty-second [ordinary scheduler runs](editor-scheduling.md) with live surface previews kept approximately 120 rendered frames/s at both grid sizes and achieved their respective 180/120 simulation ticks/s. Both small-bowl runs restored the authored build exactly and held renderer-reported video memory flat. Dense fixtures remain to be measured.

## Active follow-through

1. Make default cutaway state obvious and recoverable when it blocks Surface painting; validate the layout and real input at 1280×800.
2. Correct confirmed physical-sprite overflow holes using a deterministic derived fallback. At actual capacity, 256 excess grains and 256 excess droplets were missing from both instances and density; isolated plants also disappear under a reduced leaf budget.
3. Reduce the storage/pass cost of an [isolated GPU heat prototype](thermal-gpu.md). Its initial FP32 tests meet predeclared accuracy/conservation targets, but the straightforward 256³ experiment allocates 576 MiB and is too costly to integrate without more work.
4. Measure normal editor scheduling over longer visible runs, including achieved simulation speed, frame pacing, memory trends and exact Return. Prior short fixed-tick timings remain separately scoped.

## Architectural position

Keep the GPU material sandbox and editor as a useful product foundation. The existing cellular model alone is not a sufficient long-term architecture for all requested ambitions. General momentum, conservative heat/phase change, stress and moving rigid assemblies require explicit state and coupling contracts. The [architecture assessment](architecture-feasibility.md), [thermal reference](thermal-feasibility.md), and [momentum reference](momentum-feasibility.md) distinguish verified narrow properties from missing solver features.

GPU tests run serially in visible windows with watchdogs. Actual rendered frames are required for timing/captures. The user confirmed native trackpad behavior before this milestone; synthesized events do not establish physical macOS gesture reliability. Programmatic archive tests do not exercise the native file chooser. No broad long-session or dense-world performance claim is made yet.
