# Autonomous milestone status

Updated 2026-09-14 21:27 UTC. Work continues until the user checks in; four hours is an estimate, not a deadline. Integration checkout: `powder-game-3d-discovery/fundamentals`, branch `milestone/fundamentals`. The original main checkout is preserved.

## Current result

The project now launches the paint editor. Build on an exact workplane or an authoritative material surface, undo regional authored edits, run/pause/step an experiment, and return to the authored construction. Save/Open uses a validated, compressed authored archive; a running experiment saves its original build. Common materials are exposed first, with region and section controls optional. Trackpad navigation has native gesture handling and Option-drag fallbacks.

The simulation advances air and held sources at authoritative tick cadence. Paused rebuilds preserve temporal state. Short released paint clicks survive until the next simulation tick. Render corrections cover rigid normals, section normals/depth, and per-fragment clipping of physical sprites. These are foundations for a usable alpha, not a claim of finished visual fidelity.

Recent lifecycle review fixed legacy shortcuts advancing time while a modal owned input, async Open missing a completed live gesture, and repeated queued Run clicks toggling straight back to Build. Current screenshots are in [editor-current](editor-current/); they are short presentation captures, not frame-time evidence.

## Validation and performance

- A coordinator run of 15 GPU suites passed **484 checks**, including regional undo at 256³ and physical/render/input/archive suites at 128³. Seven CPU suites passed **94 checks**. [Combined evidence](verification.md) states the revision scope and later targeted checks.
- Latest targeted lifecycle/phase/preparation runs passed **16 + 13 + 8 + 12 + 4 GPU checks**. Gesture, paint-tool and phase CPU checks passed **10 + 9 + 9 checks**. Do not add these overlapping runs into a unique coverage total.
- Independently rerun thermal and PIC/APIC reference suites passed **22 tests**. These are isolated CPU references, not production solver capabilities.
- Short, visible editor measurements at 1600×900 found running-source mean/p95 **3.59/8.53 ms at 128³**, **11.08/11.67 ms at 256³**, at two ticks per measured frame. The small fixture, fixed workload and short duration limit generalization. [Measurement method and raw evidence](editor-performance.md).
- Render-preparation coalescing remains opt-in: it helps some repeated edit workloads but did not improve the already-combined held-source workload. An indirect physical-sprite prototype remains on its experiment branch: its clearest gain was about 0.4 ms at 256³ and it exposed a Godot command-buffer leak.

## Active follow-through

1. Exercise complete workflows with `Input.parse_input_event`, normal editor processing, GUI buttons, physical world readback, and held input. A newly found Space/GUI-focus conflict is under repair.
2. Diagnose remaining liquid section speckles with native-resolution ray captures before changing shader behavior.
3. Reproduce and correct symmetric plant exposure producing an undefined normalized origin direction, with exact GPU record comparisons.
4. Continue measured performance and architecture work after correctness checks. Preserve authored editing contracts while evaluating richer physical state.

## Architectural position

Keep the GPU material sandbox and editor as a useful product foundation. The existing cellular model alone is not a sufficient long-term architecture for all requested ambitions. General momentum, conservative heat/phase change, stress and moving rigid assemblies require explicit state and coupling contracts. The [architecture assessment](architecture-feasibility.md), [thermal reference](thermal-feasibility.md), and [momentum reference](momentum-feasibility.md) distinguish verified narrow properties from missing solver features.

GPU tests run serially in visible windows with watchdogs. Actual rendered frames are required for timing/captures. The user confirmed native trackpad behavior before this milestone; synthesized events do not establish physical macOS gesture reliability. Programmatic archive tests do not exercise the native file chooser. No broad long-session or dense-world performance claim is made yet.
