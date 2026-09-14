# Four-hour fundamentals goal

Start: 2026-09-14 20:10 UTC. Intended handoff: approximately 2026-09-15 00:10 UTC (21:10 Atlantic). Base: `62694cb`; integration branch: `milestone/fundamentals`. The user explicitly authorized an autonomous goal-driven swarm while away for about four hours. No external publishing or main replacement is required.

## Outcome

One dependable paint-and-sim loop: construct a container, fill it without damaging its walls, inspect the interior, run, paint into the live experiment, and return to the authored construction. WorldPainter remains the simple paint-first reference; advanced controls are optional. Preserve working Mac gestures and Option-drag fallbacks. Physical ambition remains richer interactions, momentum, heat, destruction and machinery; this milestone must not silently redefine that ambition as the current cellular model.

## Acceptance

1. Fixed authoritative simulation cadence: equal initial state, ordered seeded edits and absolute tick count produce identical voxel and air state across tested submission batch sizes. No change in numerical air algorithm merely because frames group ticks differently.
2. Predictable painting: workplanes remain exact; surface targeting reads authoritative occupancy with explicit add/erase semantics; stale asynchronous results cannot redirect a newer gesture. Held emission is time-based, bounded under stalls and independent of ordinary render FPS. Navigation never becomes painting.
3. Ordinary construction strokes no longer copy the whole volume to the CPU for undo. Bound history memory and transfer data to changed regions/commands. Exact packed-byte undo and wall preservation remain verified. Separate authored restore from runtime rewind.
4. Readable geometry and materials: investigate and fix at least a demonstrated surface/coverage defect, preserve all physical representations, and make the milestone editor useful for inspection. Matched captures and unchanged physical-state checks distinguish appearance from physics changes.
5. Integrated runnable editor, regression results, measured limitations and a concise handoff. Performance aspiration on this M5 Pro is a responsive 128³ editor at 60 FPS with short painting latency; report achieved frame/latency distributions and 256³ scaling rather than declaring the aspiration met from an unrelated benchmark.

If the main loop is achieved with time remaining, run a bounded richer-physics feasibility experiment. Do not rush an unmeasured solver replacement into the playable path.

## Shared contracts

- Coordinates: integer cell indices `[0, GRID)`; region upper bounds are exclusive; one cell remains 0.01 m. Camera and shading do not change editing coordinates. Bounds must be clamped at the public editing boundary.
- State: GPU voxels/solver fields are authoritative. Use monotonic state/edit generations to associate asynchronous picks and undo results with the correct gesture; a readback is not permission to apply stale UI state.
- Edit commands: ordered stamps/regions with explicit material, radius/shape, fill/replace/erase policy and deterministic seed where replay matters. Freeze gesture metadata at gesture start. Return concrete changed bounds/data for undo, and flush render preparation after an ordered batch.
- Time: solver cadence is tied to absolute simulation ticks. Submission and completion are distinct; do not label a render-thread submission as GPU completion. Rendering preparation and temporal foam/FX progression must not accidentally define physics time.
- Presentation: sections never erase physical state. Opaque, liquid, gas and required grain/droplet/leaf representation share clipping and generation. Decorative FX may be simplified without deleting physical representation.
- Authoring: Build undo restores authored edits. Live painting changes the running experiment. Return restores the authored revision and resets appropriate solver/presentation state; it does not claim a full runtime rewind unless complete state is captured.

These are semantic contracts, not a forced framework. Keep implementation small enough to validate. Workers agree method signatures directly before depending on new APIs.

## Ownership and coordination

| Worker | Workspace / branch | Main ownership |
|---|---|---|
| simulation | fundamentals-simulation / milestone/simulation | fixed cadence, `time_controller.gd`, tick/reset/derived scheduling in `voxel_sim.gd`, temporal fields/FX, physics regression |
| editing | fundamentals-editing / milestone/editing | editor flow, targeting, bounded undo/emission; additive GPU editing/picking APIs and kernels; input regression |
| rendering | fundamentals-rendering / milestone/rendering | spatial shaders, material/presentation settings, surface coverage, matched visual evidence |
| coordinator | fundamentals / milestone/fundamentals | contracts, integration, independent tests, workload/latency evidence, reviews and final handoff |

`voxel_sim.gd` is shared by method ownership: simulation owns tick/reset/derived functions; editing owns new edit/readback/pick methods and their resource lifecycle. Communicate additions before crossing ownership. Rendering must coordinate changes to `fields.glsl` or simulator internals rather than independently changing temporal/scheduling semantics. No worker changes the working gesture routing without a demonstrated regression.

Commit small coherent units for integration. Do not rebase or merge another worker's work without coordinator instruction. Report evidence and remaining risks, not only implementation claims. The coordinator can return work for another iteration and reuse completed workers for independent review or feasibility work.

Only one new GPU validation process at a time, assigned by coordinator. Use visible `--always-on-top --disable-vsync` windows, bounded timeouts and fixed workloads. CPU work and headless input tests can run concurrently. Existing user's Godot session must not be killed or have its world reset. Historical audit/discovery screenshots must not be overwritten as evidence of new behavior.
