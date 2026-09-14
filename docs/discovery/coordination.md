**Discovery swarm — 14 September 2026**

Authorized scope: three independent discovery prototypes and an evidence-backed architectural recommendation, before a full overhaul. Base commit: `494a1b1`. Superset CLI authentication is unavailable; orchestration uses the session's agent tools and isolated Git worktrees.

| Task | Dependencies | Workspace | Host | Agent | Status | Result |
|---|---|---|---|---|---|---|
| interaction | shared brief | ../powder-game-3d-discovery/interaction | local | /root/interaction | complete | 3dcfbc1; interaction.md |
| simulation | shared brief | ../powder-game-3d-discovery/simulation | local | /root/simulation | complete | 878f2b6; simulation.md |
| rendering | shared brief | ../powder-game-3d-discovery/rendering | local | /root/rendering | complete | b51243c; rendering.md |
| synthesis | all three reports | ../powder-game-3d-discovery/review | local | /root | complete | summary.md, review.html, integration-evidence/ |

User clarified: “All of the above. I think fundamentals first though.” Long-term scope includes precise construction and rich interactions, physically convincing fluids/destruction/moving machinery, and visual realism. Discovery prioritizes reliable editing, simulation behavior, and measured performance while preserving that broader scope. No engine replacement, large sparse-world rewrite, or production quality claim is implied.

**Shared evaluation task.** Place a container precisely, add water or sand without overwriting its walls, observe the result, and inspect its interior. Interaction evaluates construction and visibility; simulation evaluates edit/tick scheduling and scalable state; rendering evaluates readable material appearance under matched scene and camera conditions. Future save/undo/selection requirements must inform interfaces without forcing all those features into discovery.

**Candidate system boundary.** These are discussion contracts, not final APIs:

- Coordinates are explicit integer cells with separately reported physical cell size and world extent. Camera or rendering quality must not silently change the meaning of an edit.
- An edit is a command with shape, coordinates, material, fill/replace/erase policy, and stroke identity. A stroke may contain many stamps but should incur one scheduled derived-data rebuild per frame, not one rebuild per stamp.
- Paused construction and running simulation have explicit semantics. Undoing construction is not automatically rewinding a physically evolving world; prototypes must disclose the distinction.
- Simulation remains authoritative. Rendering and cutaway views never erase hidden matter. Picking must declare whether it targets a workplane, occupied cell, or reconstructed visible surface.
- Simulation advancement reports requested and completed work distinctly where necessary; elapsed wall time and rendered frames must be verified during benchmarks.
- Derived rendering work consumes simulation/edit changes after their ordered application. Chunking, sleep, or sparse storage must account for hydro lines, pressure fields, and dependencies across region boundaries.
- Rendering detail and material appearance are evaluated independently from simulation correctness. Visual changes do not silently alter material rules.

**GPU protocol.** One coordinator-issued GPU lease at a time. Headless CPU checks/imports may run concurrently. Windowed Godot tests/captures use `--always-on-top` to avoid the observed macOS obscured-window stalls. Benchmark runs disable VSync and record scene, grid, window/internal resolution, camera, simulation state, warmup, measurement length, and limitations. Equal camera plus equal initial seed is insufficient if the compared runs advance different tick counts. Preserve fixed-state images for appearance comparisons.

**Completion.** Every worker provides runnable commands, source changes, evidence, measured or tested results, limitations, and an exact branch commit. Coordinator reviews risky changes and reruns meaningful checks. Prototypes remain isolated for evaluation unless combining them is justified and verified. Reports must distinguish measurements from hypotheses.

GPU leases completed serially: simulation, rendering, interaction, coordinator integration. No lease remains active.

**Accepted editor references.** WorldPainter is the primary reference for casual paint-and-sim. Amulet/MCEdit inform optional advanced authoring and Besiege informs the build–test–return workflow. WorldEdit region, mask, and brush semantics remain useful secondary prior art. This is a workflow reference within the high-fidelity goal, not a requirement to reproduce Minecraft graphics or build a command-driven interface.

The discovery editor should expose a coherent slice: explicit tools, visible selection bounds, precise numeric workplane/region controls, material operations, undo, and a clear distinction between authored construction and running simulation. Long-term manipulation handles, clipboard/prefabs, robust persistence, and complete multi-object editing remain requirements to plan rather than claim finished in discovery.

References: [Amulet source](https://github.com/Amulet-Team/Amulet-Map-Editor), [MCEdit](https://www.mcedit.net/), [WorldEdit selection documentation](https://worldedit.enginehub.org/en/latest/usage/regions/selections/). User-supplied qualitative reference: Besiege.

Latest steering: WorldPainter is now the primary paint-centric reference. Default flow is casual material painting with simulation, advanced authoring optional. Preserve robust operations and authored/runtime separation underneath; live painting during Test is allowed as runtime-only changes.
