# Discovery result: keep the useful infrastructure, reconsider the core model

The current implementation is useful as an experimental GPU sandbox, but I would not extend it unchanged into the intended game. The main problems cross subsystem boundaries: painting triggers expensive global preparation, simulation behavior depends on tick batching, the compact material state omits important physical quantities, and reconstructed surfaces do not provide dependable editing targets. More elements and visual effects would leave those problems in place.

The recommendation is a staged architectural overhaul. Keep Godot and the GPU infrastructure provisionally; establish explicit editing, state and time contracts; then compare physical models against a small playable task before choosing the permanent backend. This discovery does **not** establish that Godot must be replaced, that sparse voxels solve the physics problem, or that one particular fluid solver is the answer.

Three agents produced isolated experiments. Their commits are combined on local branch **`discovery/review`**, in `../powder-game-3d-discovery/review`, based on `494a1b1`. The original checkout's implementation has not been replaced. The combined branch is for review: the coalescing and rendering studies remain separate opt-in harnesses; the editor does not automatically inherit their experimental scheduling or appearance.

[Visual comparison gallery](review.html) · [Original audit](../current-implementation-audit.md) · [Interaction report](interaction.md) · [Simulation report](simulation.md) · [Rendering report](rendering.md)

## What the experiments establish

| Finding | Evidence | Consequence |
|---|---|---|
| Tick grouping changes physical outcomes | Forest fire, same initial state and 60 ticks: groups of one versus three give different voxel and air hashes with air enabled; identical hashes with air disabled | Solver cadence must depend on simulation time. Rendering or submission batching must not change the algorithm. |
| Painting pays avoidable rebuild cost | Two controlled 256³ comparisons: mean frame time 26.67 → 21.91 ms and 24.96 → 21.01 ms; all ten workload/repeat pairs preserve voxel and air hashes | Consolidate render preparation after ordered edits and ticks. The observed 16–18% improvement is useful but does not reach 60 FPS or establish scalable worlds. |
| Rebuild frequency also controls appearance | Foam decays per rebuild and FX use rebuild-related seeds | Coalescing is not yet a production-safe visual change. Explicit temporal updates are part of the refactor. |
| Reliable editing is possible with the existing GPU backend | Prototype tests cover exact camera-to-plane targeting, connected strokes, preserved walls, exact-byte construction undo, live edits and authored-state restoration | The editor can evolve independently of solver replacement if commands and picking have stable contracts. |
| Simpler presentation improves readability, without a demonstrated speedup | Frozen, matched-camera material and dam scenes; unchanged voxel hashes; render timing ranges overlap | Establish material readability and geometric correctness before adding effects. This is a diagnostic look, not the high-fidelity target. |
| The current state model is too narrow for the whole ambition | Four packed bytes per cell encode material, seed, amount and flags; no persistent per-material momentum, temperature or dynamic-body model | Chunking can reduce storage/work, but richer physics requires more state and suitable transport/coupling solvers. |

The original Powder Toy already stores particle position, velocity, temperature and auxiliary state. Our current model is a physical simplification as well as a move to 3D. [Upstream Particle.h](https://raw.githubusercontent.com/The-Powder-Toy/The-Powder-Toy/master/src/simulation/Particle.h)

All timings are from one Apple M5 Pro, Godot 4.6.3/Metal, with visible windows and controlled workloads. The performance comparison uses two ticks per rendered frame, 30 warmup and 120 measured frames per case. It is not a measurement of the editor's snapshot undo or of a finished game's sustained performance. See the simulation report for controls, raw hashes and presentation caveats.

## The product direction

**WorldPainter is the primary interaction reference:** choose a material, see the footprint, paint, and watch the experiment. Its paint-program approach is the relevant reference; our adaptation must also solve targeting and occlusion in a live 3D simulation. [WorldPainter](https://www.worldpainter.net/)

Keep the robust operations underneath that simple flow: additive and destructive policies, dependable undo, persistence, optional regions and numeric coordinates, and inspection without deleting hidden material. Amulet/MCEdit inform the advanced tools; the user's Besiege reference informs a dependable build/run/return loop. Precise authoring should be available without making it a prerequisite for casual painting. [Reference brief](editor-references.md)

The prototype demonstrates construction planes, not the complete painting solution. Surface-following paint and a timed emission tool are still needed. A held stationary brush currently emits once. The editor also exposes too many advanced controls at once for the desired final default. Its noisy water/wall rendering and basic panels are visibly unfinished.

## Architecture to retain, change and investigate

**Retain provisionally:** GPU-resident simulation resources, existing compute submission infrastructure, regression scenarios, and the ability to render without copying the whole world to the CPU each frame. Keep the dense backend as a comparison oracle while changing scheduling. Preserve the tests for mass, containment, pressure communication, material rules and sprite representation.

**Change first:** create one owner for ordered edit transactions, authoritative state generations and fixed simulation time. An edit must declare its coordinates, mask, seed and application tick. Rendering should consume a completed state generation and dirty dependencies. Separate authored revisions from complete runtime snapshots. Production undo needs changed-region data or reversible commands instead of a full-volume readback on every stroke.

**Investigate before committing:** how momentum-carrying liquid, heat/chemistry, granular material and moving structures share space and exchange mass/forces. A particle/grid or other hybrid approach is a candidate, not a selected implementation. Compare it against the current backend on a momentum-carrying pour, containment, pressure communication, heat transfer and a moving obstacle. Define target world extent, material density, fidelity and hardware budgets alongside that experiment; the discovery has not established those budgets.

Active dispatch and sparse storage are separate decisions. Start by measuring active work against dense storage. Existing hydro updates whole connected lines, coarse air pressure has wider dependencies, and sunlight changes propagate downstream. An agent cannot safely optimize each tile in isolation without preserving those dependencies. Likewise, changing opaque structures to meshes is worth comparing, but this study did not benchmark meshes against raymarching.

## How to parallelize the next phase

The discovery split worked: interaction, simulation and rendering could proceed independently, while integration exposed shared assumptions. The full overhaul should use the same separation after agreeing on the contracts. More agents do not remove the need for one owner of state and solver coupling.

| Workstream | Independent work after the contract is agreed | Shared dependency / acceptance |
|---|---|---|
| State and time | Fixed solver cadence; requested/completed tick reporting; reproducible edit replay; presentation timing | Own the state schema and scheduling contract. Same commands and ticks must produce the same physical result across submission batch sizes. |
| Paint and authoring | Surface/workplane targeting; brush previews; stroke transactions; delta undo; authored saves | Consume versioned picking/edit APIs. Build a container, fill without breaking walls, inspect, run, live-paint and restore. |
| Rendering | Surface artifacts; material readability; representation ownership; matched mesh/raymarch experiments | Consume the same completed state and section controls. No grains or thin liquid disappear when changing representations. |
| Physics feasibility, subsequent bounded spike | Momentum/thermal/body coupling and measured richer-state cost | Needs an agreed minimal scene and conservation requirements before selecting the permanent model. |

With four agent slots, use one coordinator and three implementation workers; schedule the physics spike as a focused phase or reuse a completed worker. Keep GPU benchmarks serialized on this machine. Source work, CPU checks and reviews can run concurrently. Integration, interface changes, physical conservation decisions and human usability evaluation remain coordinated work.

The next reviewable milestone should be **one dependable paint-and-sim loop** with explicit performance and correctness budgets. Expanding the element catalog, producing final art, or rewriting world storage should follow evidence from that loop and the physical-model experiment. These are recommendations for discussion, not an already-started full rewrite.

## Try the discovery editor

```sh
cd /Users/benjo/.superset/projects/powder-game-3d-discovery/review
godot --path . --always-on-top res://scenes/discovery/interaction.tscn -- grid=128
```

Choose Water or Sand, draw across the tank, then Space to run. Live painting is allowed. Space again restores the authored voxel arrangement. Right-drag orbits, V faces the selected workplane, F gives an angled view, and Shift-wheel moves the plane one cell. Undo is available in Build. The complete controls are in [interaction.md](interaction.md).

This is a functional discovery prototype. Undo retains at most 128 MiB of voxel snapshots: 16 at 128³, only two at 256³, plus a separate build snapshot during play. Readbacks can stall. Return-to-build restores authored voxel bytes and resets air through the upload path; it does not rewind all transient foam/FX history. There is no persistence, redo, surface picking or completed casual-player usability study.

## Verification and limits

Worker evidence includes 37 existing CPU checks, 20 interaction geometry/time checks, 74 existing GPU checks at 128³, three default-grid 256³ smoke checks, 19 interaction GPU acceptance checks (including two capture checks), deterministic coalescing comparisons and frozen rendering comparisons. Automated input tests call the editor handler and use the real camera; they do not establish human mouse usability.

The coordinator independently imported the combined branch and reran the 37 + 20 CPU checks, 74 GPU128 checks and 19 interaction acceptance checks successfully. Integration logs are in [integration-evidence](integration-evidence/). A shorter 256³ coalescing replay and frozen render rerun additionally check combined-branch behavior; their completion and any caveats are recorded in [integration verification](integration-evidence/README.md). The original longer worker measurements remain the source for the performance table above.

Known issues remain: tick-batch divergence is diagnosed, not fixed; visual artifacts persist; whole-world preparation and snapshot undo remain expensive; and research harnesses emit a Godot ObjectDB teardown warning. Passing the existing rules suite does not certify the architecture or make the alpha playable. The value of discovery is that the next decisions now have concrete failure cases, working interaction examples and measured limits.
