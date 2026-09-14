**Editor reference brief — accepted user direction**

The user wants a robust authoring experience with precise construction, rich material simulation, and visual realism. Fundamentals come first. WorldEdit was the initial reference; Amulet/MCEdit subsequently became the preferred editor references, with Besiege supplying the desired feel. The latest clarification makes WorldPainter the primary interaction reference: paint-centric casual paint-and-sim, without cumbersome mandatory editing workflows. Amulet/MCEdit remain advanced-tool references and Besiege remains a build/test reference.

| Reference | Grounded reference behavior | Application to this project |
|---|---|---|
| [Amulet](https://www.amuletmc.com/) / [source](https://github.com/Amulet-Team/Amulet-Map-Editor) | Dedicated editor; fill/replace selections, clipboard, structure import/export | Persistent tool panels, explicit selections and operations, authoring as a first-class activity |
| [MCEdit](https://www.mcedit.net/) | 3D world/map/terrain editing; manipulation such as rotation | Spatial selection, clear handles and previews, numerical control, scene navigation that supports editing |
| [WorldPainter](https://github.com/Captain-Chaos/WorldPainter) | Paint-program-style terrain sculpting and painting materials/vegetation | Brush shape/radius/strength/falloff controls, material palettes, terrain tools, eventual masks/layers |
| [WorldEdit](https://worldedit.enginehub.org/en/latest/usage/regions/selections/) | Two-corner regions, explicit coordinates, region resizing and counting | Useful region/operation semantics beneath the graphical editor; optional future power-user commands |
| Besiege (user-supplied experience reference) | User identifies it as the desired editor/build feel | Our proposed adaptation: build, test, inspect, return to the authored construction reliably |

The right-hand column is our design interpretation, not a claim that each named application has the exact proposed UI or feature. Sources were inspected on 14 September 2026. No reference application's code or artwork has been copied into the prototype.

A practical editor shell has a central viewport, visible active tool and selection, a material/tool panel, numeric properties for what is being edited, and a persistent Build/Test state control. Contextual controls should expose the current operation without making users memorize commands. Brush previews, region dimensions, and occlusion/section controls should give immediate feedback before changes occur.

Authoring must preserve intent independently of simulation: a container stays as the user authored it when returning from a destructive test. Pausing an evolving world is a separate action. Applying test changes back into the authored scene should be explicit. This boundary supports undo, repeatable experiments, saves, prefabs, and eventually machines or terrain.

This brief expands the long-term editor requirements; it does not claim that a short discovery prototype implements a complete Amulet/MCEdit/WorldPainter feature set. The current slice remains container construction, precise material placement, region operations, inspection, and a build/test state boundary. Terrain layers, full transform gizmos, prefabs, disk persistence, and complex mechanical assembly need subsequent work.

**Latest priority: painting first.** Pick material, see the brush footprint, paint predictably, and watch the simulation. Live painting during a running experiment is part of the basic loop. Authored build state and runtime edits remain distinct, with Return to build restoring the former. Advanced region operations, exact coordinate entry, and inspection controls should be progressively available rather than prerequisites for drawing. The default editor should communicate active material, brush radius/shape, targeting surface/plane, and play/pause state clearly. A future surface-following terrain brush is distinct from a volume brush/workplane and must expose that distinction.

This supersedes the earlier interpretation of a panel-heavy dedicated editor as the default. Robust underlying operations, undo, and persistence remain requirements; the user prefers a simple default interaction over exposing every control at once.
