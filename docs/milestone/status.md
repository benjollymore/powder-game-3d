# Autonomous milestone status

Updated 2026-09-14 22:45 UTC. Work continues until the user checks in; four hours is an estimate, not a deadline. Integration checkout: `powder-game-3d-discovery/fundamentals`, branch `milestone/fundamentals`. The original main checkout is preserved.

## Current result

The project now launches the paint editor. Build on an exact workplane or an authoritative material surface, undo regional authored edits, run/pause/step an experiment, and return to the authored construction. Save/Open uses a validated, compressed authored archive; a running experiment saves its original build. Common materials are exposed first, with region and section controls optional. Trackpad navigation has native gesture handling and Option-drag fallbacks.

The simulation advances air and held sources at authoritative tick cadence. Paused rebuilds preserve temporal state. Short released paint clicks survive until the next simulation tick. Render corrections cover rigid normals, section normals/depth, and per-fragment clipping of physical sprites. These are foundations for a usable alpha, not a claim of finished visual fidelity.

Recent lifecycle review fixed legacy shortcuts advancing time while a modal owned input, async Open missing a completed live gesture, and repeated queued Run clicks toggling straight back to Build. Current screenshots are in [editor-current](editor-current/); they are short presentation captures, not frame-time evidence.

Subsequent active-input testing fixed Space also activating a focused GUI button. The [complete workflow](editor-workflow.md) now exercises held painting, GUI controls, paused clicks and exact Return through ordinary editor processing. [Symmetric leaf origins](leaf-origin.md) are finite, and [liquid segments now close correctly](liquid-edge-noise.md) after delayed density exits. Both rendering fixes preserve physical bytes.

[Regional Redo](editor-redo.md) is integrated, with validated inverse capture, one shared past/future history budget, no-op branch preservation, and exact Run/Return behavior. The coordinator reran it at both grid sizes and preserved raw logs. [Cutaway recovery](surface-feedback.md) makes blocked surface painting explicit and recoverable; [toolbar input boundaries](gui-crossing.md) prevent unintended connecting strokes between frames. The editor now offers a saved [Sharper/Faster picture preference](display-quality.md), defaulting to native-resolution FXAA.

## Validation and performance

- [Rapid authored paint](pending-paint.md) now retains one bounded gesture during asynchronous history capture. Coordinator GPU reruns pass 28 checks at each grid size; focused CPU checks cover seven pending-gesture, 19 history and seven archive cases. [Evidence](pending-integrated/).
- [Physical capacity fallback](material-capacity.md) and [water interfaces](material-interface.md) are integrated. Coordinator reruns pass 74 simulation, 112 capacity, 145 proxy geometry, 66 interface, 61 section-depth and 102 liquid-exit checks. Coverage survives overflow, with a conspicuous coarse representation at the threshold; this is not final visual fidelity. [Evidence](capacity-integrated/).

- A coordinator run of 15 GPU suites passed **484 checks**, including regional undo at 256³ and physical/render/input/archive suites at 128³. Seven CPU suites passed **94 checks**. [Combined evidence](verification.md) states the revision scope and later targeted checks.
- Latest targeted lifecycle/phase/preparation runs passed **16 + 13 + 8 + 12 + 4 GPU checks**. Gesture, paint-tool and phase CPU checks passed **10 + 9 + 9 checks**. Do not add these overlapping runs into a unique coverage total.
- Independently rerun thermal and PIC/APIC reference suites passed **22 tests**. These are isolated CPU references, not production solver capabilities.
- Short, visible editor measurements at 1600×900 found running-source mean/p95 **3.59/8.53 ms at 128³**, **11.08/11.67 ms at 256³**, at two ticks per measured frame. The small fixture, fixed workload and short duration limit generalization. [Measurement method and raw evidence](editor-performance.md).
- Render-preparation coalescing remains opt-in: it helps some repeated edit workloads but did not improve the already-combined held-source workload. An indirect physical-sprite prototype remains on its experiment branch: its clearest gain was about 0.4 ms at 256³ and it exposed a Godot command-buffer leak.
- Later integrated checks passed **203 leaf checks**, **102 liquid-path checks**, **61 section-depth checks**, and **24 full workflow checks**, with archive/action guards rerun. [Profiling and integration evidence](gpu-profiling.md). GPU timestamp reporting now explicitly reports unavailable data on the pinned Metal backend rather than zero pass cost.
- Twenty-second [ordinary scheduler runs](editor-scheduling.md) with live surface previews kept approximately 120 rendered frames/s at both grid sizes and achieved their respective 180/120 simulation ticks/s. Both small-bowl runs restored the authored build exactly and held renderer-reported video memory flat. Four later reservoir/forest runs also maintained target simulation rates and exact Return; the 256³ reservoir averaged 89 rendered frames/s at the former 0.75 scale. Native-resolution FXAA averaged 83 frames/s in a separate reservoir run. These remain short, scoped measurements.

## Active follow-through

1. Protect unsaved authored builds when Reset, Empty, Open or normal window close would replace them. Exact saved checkpoints must survive Undo/Redo and reject stale asynchronous Save completion as permission to discard newer edits.
2. Fix a separate ordinary-liquid omission: paused isolated water/oil cells can be pickable but invisible even without overflow. A pinned negative control reproduces this with actual radius-zero painting; a bounded thin-feature representation is being evaluated.
3. Review finite-motion GPU PIC/APIC against the binary64 reference. The [enthalpy transport reference](enthalpy-transport.md) now demonstrates two conservative routes for the same production amount update; production still needs an explicit accepted-transfer contract. The [stationary thermal comparison](thermal-cached.md) remains an isolated 256 MiB, 13.2 ms/four-step candidate at 256³, not production thermal physics.
4. Continue integrated repeated-session checks through ordinary input, periodic asynchronous Save/Open, retained history, memory trends and exact authored Return. Initial 128³ smoke passed five complete cycles; longer measurements are underway with explicit viewport settings.

## Architectural position

Keep the GPU material sandbox and editor as a useful product foundation. The existing cellular model alone is not a sufficient long-term architecture for all requested ambitions. General momentum, conservative heat/phase change, stress and moving rigid assemblies require explicit state and coupling contracts. The [architecture assessment](architecture-feasibility.md), [thermal reference](thermal-feasibility.md), and [momentum reference](momentum-feasibility.md) distinguish verified narrow properties from missing solver features.

GPU tests run serially in visible windows with watchdogs. Actual rendered frames are required for timing/captures. The user confirmed native trackpad behavior before this milestone; synthesized events do not establish physical macOS gesture reliability. Programmatic archive tests do not exercise the native file chooser. No broad long-session or dense-world performance claim is made yet.
