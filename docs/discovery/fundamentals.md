**Fundamentals for the intended game**

The user wants construction depth, convincing physical behavior, and visual realism, with fundamentals first. These goals remain in scope; the discovery prototypes validate narrow parts of the foundation rather than redefining the final game around what is easiest to implement.

| Fundamental | Observable requirement | Architectural consequence |
|---|---|---|
| Editing intent | The same authored point/shape lands in the same cells regardless of camera or frame rate | Explicit workplanes/surface targeting, continuous command strokes, deterministic coordinate transforms |
| Containment | Filling a container does not erase its walls and fluid does not leak through them | Additive material policy, collision/boundary invariants, amount conservation checks |
| Inspection | Look inside an experiment without physically cutting it apart | Rendering-only cutaways, overlays, clear picking semantics |
| Time | Pause, step, and speed mean what the UI says; hardware does not silently change rule meaning | Explicit simulation clock, overload reporting, controlled solver substeps |
| Recoverability | Undo an authored edit, save a world, and restore consistent state | Edit history and full state snapshots are separate concepts; version the state format |
| Material dynamics | A pour can carry momentum; heat can be stored/transferred; structures can eventually move or fail | Four bytes of element/seed/fill/activity are insufficient as the entire authoritative material state |
| Visual truth | What appears present/absent matches the simulation and targeting | Representation changes and cutaways must preserve material identity and explain hidden matter |
| Performance | Small edits and settled scenes do not automatically pay the worst-case world cost | Batch transactions, dirty dependencies, active work accounting, render and sim budgets |
| Extensibility | New elements and machinery do not require every subsystem to be rewritten | Material properties, solver state, edit commands, and render views have explicit boundaries |

**Reference-model check.** The original Powder Toy is not solely an element ID grid. Its Particle struct stores floating position and velocity, temperature, life, and element-specific state. This is directly visible in [upstream Particle.h](https://raw.githubusercontent.com/The-Powder-Toy/The-Powder-Toy/master/src/simulation/Particle.h), inspected on 14 September 2026. The current project is therefore a deliberately smaller physical model, not just the same state model expanded to three dimensions.

**Candidate physical-model direction, not a selection.** Richer continuous dynamics may call for particle/grid or other hybrid solvers. The [MPM lecture by Chang Yu](https://phys-sim-book.github.io/material-point-method/spatial-and-temporal-discretization/mpm_disc.html) describes persistent particles carrying mass, momentum, deformation and stress with temporary grid computation. This establishes a relevant model family; it does not establish that an MPM implementation will meet this game's interactive budget or construction requirements. A solver decision needs its own measured prototype. Rigid machinery, heat/chemistry, and liquid free surfaces introduce different requirements even when sharing spatial data.

The immediate experiments should establish reliable editing and scheduling contracts that survive a future solver change. They should also expose where additional state belongs. Selecting a permanent four-byte dense CA format now would make the user’s broader ambition harder to reach.
