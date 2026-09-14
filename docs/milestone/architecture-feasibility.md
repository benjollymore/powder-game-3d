# Architecture feasibility: physical state before visual detail

The existing GPU cellular world is a useful bounded paint-and-sim baseline. It is not yet a foundation for believable momentum, heat transport, or load-bearing construction merely waiting for more element rules. Those ambitions require additional authoritative state and different update operators. The renderer and editor can survive that evolution if they consume explicit material surfaces and edit commands rather than treating the four-byte voxel texture as the permanent definition of the entire world.

This is a feasibility assessment, not a recommendation to replace the engine. Three compatible directions deserve small discriminating experiments: retain cellular materials while adding conservative fields; prototype momentum-bearing material in a bounded particle/grid region; represent constructed assemblies as rigid bodies with explicit material coupling. Keep the current solver as the comparison and regression baseline until a candidate passes physical and interaction tests.

Source inventory: integration checkout `milestone/fundamentals`, inspected through `3e38ac260b0a73cbd193513f4a22f0714ceb26cc` on 2026-09-14. No new GPU measurements were made for this document. Existing editor/performance reports remain the measurement authority; dispatch counts below are source arithmetic, not timings. Proposed numerical tolerances and budgets below are experiment gates, not achieved results.

## What actually exists

[`voxel_sim.gd`](../../scripts/sim/voxel_sim.gd) allocates a dense `N³` world at one centimetre per cell: 1.28 m at 128 and 2.56 m at 256. [`sim.glsl`](../../shaders/compute/sim.glsl) moves material through disjoint 2×2×2 partitions. [`hydro.glsl`](../../shaders/compute/hydro.glsl) redistributes integer liquid amounts within contiguous runs: hydrostatic vertical profiles, then horizontal relaxation toward a run mean. It preserves liquid amount in transport but does not advect liquid momentum. Fast redistribution along a pipe is therefore not evidence of a pressure-wave or inertial fluid model.

The packed voxel is four bytes: element ID, seed, liquid amount, and movement/age flags. Header comments still calling the fourth byte “reserved” are stale. There is no per-material velocity, temperature, enthalpy, stress, charge, or connected body identity. [`elements.gd`](../../scripts/sim/elements.gd) has ten IDs including air and five pair reactions. Its `heat` is a constant buoyancy source by element type. [`air_downsample.glsl`](../../shaders/compute/air/air_downsample.glsl) averages those constants over 4³ blocks; the air solver advects a heat proxy alongside velocity. This is not material heat capacity, conduction, or an energy ledger for boiling and combustion.

Grain and droplet instances are derived representations of actual voxel material. [`fields.glsl`](../../shaders/compute/fields.glsl) deliberately omits some airborne grains and thin falling liquid from the reconstructed surfaces because those instances show them. Leaves also derive from plant cells. Hiding those layers can erase visible physical material. In contrast, the persistent ember/dust/splash pool in [`fx.glsl`](../../shaders/compute/fx.glsl) is cosmetic; its velocities are not the underlying sand/water momentum. Foam is a temporal appearance channel, not transported mass.

## Storage and work growth

Reproduce the allocation arithmetic without starting Godot:

```sh
python3 tools/feasibility/storage_budget.py --grid 128 256 512
# Optionally inventory capacities/constants from the integration checkout:
python3 tools/feasibility/storage_budget.py --source-root /path/to/fundamentals
```

The script reads current capacities and grid-ratio constants. Byte formats and the ten-element/five-reaction table are the explicitly inventoried layout, not automatic shader reflection. Totals exclude driver alignment, shader/pipeline resources, Godot caches, material textures, framebuffers, editor staging, undo data, and CPU snapshots. Shared texture mip views do not duplicate the fields texture. Units are MiB (2²⁰ bytes); 512 is an arithmetic extrapolation, not a supported-performance claim.

| Resource | Exact logical storage | 128³ | 256³ | 512³ |
|---|---:|---:|---:|---:|
| Physical voxel RGBA8 | 4N³ | 8 | 64 | 512 |
| Render fields RGBA8, five mip levels | 4Σ(N/2ᵐ)³, m=0…4 | 9.143 | 73.141 | 585.125 |
| Occupancy RGBA8, 8³ bricks | 4(N/8)³ | 0.016 | 0.125 | 1 |
| Sun visibility R8, half resolution | (N/2)³ | 0.25 | 2 | 16 |
| Air textures, quarter resolution | 31(N/4)³ | 0.969 | 7.75 | 62 |
| Four render instance buffers | 64 bytes × fixed capacities | 30 | 30 | 30 |
| Persistent cosmetic FX state | 48 × 32,768 | 1.5 | 1.5 | 1.5 |
| FX requests | 32 × 4,096 | 0.125 | 0.125 | 0.125 |
| Counters + element/reaction tables | 128 + 320 + 80 bytes | <0.001 | <0.001 | <0.001 |
| **Accounted total** | | **50.002** | **178.641** | **1,207.751** |
| One CPU voxel snapshot, additional | 4N³ | 8 | 64 | 512 |

Each coarse air cell uses two RGBA16F velocity/heat images (16 bytes total), two R16F pressure images (4), R16F divergence (2), R8 occupancy (1), and RGBA16F source (8): **31 bytes**. Each render instance is a 12-float transform plus four custom floats: **64 bytes**. Scene capacities are grains 131,072 (8 MiB), leaves 262,144 (16), droplets 65,536 (4), and FX 32,768 (2). These capacities are ceilings, not counts of live physical particles. The cosmetic pool additionally stores three vec4s per slot: position/lifetime, velocity/kind, seed/age.

The newest fixed-tick scheduling in `_rt_tick` does the following with all default subsystems enabled:

| Cadence | Work | Default dispatch count |
|---|---|---:|
| Every simulation tick | Air downsample, advection, divergence, 20 Jacobi iterations, projection | 24 |
| Every simulation tick | One Margolus material pass | 1 |
| Every simulation tick | Vertical hydro + alternating X/Z hydro | 2 |
| Every derived rebuild | Occupancy + physical sprite emission + fields + four mip passes | 7 |
| Every derived rebuild | Half-resolution sun sweep, eight slabs/dispatch | N/16 |
| Every advancing submission | Cosmetic FX update | 1 |

Thus default physics submits **27 dispatches per tick**; derived geometry submits **15 at 128 or 23 at 256** per rebuild, plus optional edit/emitter work. Derived reconstruction occurs once after a submitted tick batch, and on edit refreshes. Geometry-only refreshes do not advance simulated time. Counting these as 27 equal full-grid passes would be misleading: most air operations visit only `(N/4)³` cells. However, air downsampling reads all N³ voxel cells each tick. Both hydro passes dispatch N² line owners scanning N cells, with liquid runs reread. The cellular pass covers approximately N³ cells through 2³ blocks, including boundary dispatch padding.

Derived work also remains global. Occupancy scans up to 512 voxels per brick, with early exit after finding both solid and fluid. Sprite emission dispatches across N³ and skips empty bricks, but first clears **28 MiB of grain/leaf/droplet instance storage per rebuild** regardless of live count. Fields stage a 10³ neighbourhood per 8³ workgroup, then evaluate a 27-tap shared-memory stencil; classification performs additional material-dependent neighbour reads. Four mip passes shrink the volume; the sun sweep propagates dependencies along an entire half-resolution axis. An empty or small painted scene still pays much of this preparation cost.

Doubling world side at fixed cell size multiplies dense storage and most scan work by eight. Keeping the world size fixed while doubling resolution also increases physical accuracy demands and can require smaller stable time steps in future continuum solvers. Adding only two FP32 enthalpy buffers costs another **16 MiB at 128, 128 MiB at 256, or 1 GiB at 512**, before velocity/stress fields. Large terrain at centimetre resolution needs a spatial/activity strategy; increasing the global grid is not sufficient.

## Renderer suitability and the interface worth preserving

[`voxel_opaque.gdshader`](../../shaders/spatial/voxel_opaque.gdshader) and [`voxel_volume.gdshader`](../../shaders/spatial/voxel_volume.gdshader) traverse bounding boxes with per-pass loop limits of `3N`. Empty 8³ bricks skip rapidly; surfaces and opaque depth terminate rays. Consequently rendering scales with occupied ray length, screen coverage, material composition, camera, and output resolution. Simulation and derived preparation scale with world data even when it is off screen. Section views shorten rendering bounds but do not reduce the physical simulation domain. A larger grid does not predict a unique frame time.

The current split is plausible for a small inspectable material volume: exact voxel boundaries for built walls, reconstructed sand/water surfaces, participating gas, and mandatory sparse material instances. It has proven correctness defects we can fix independently of physics: see [surface-normal evidence](rendering-surfaces.md) and [liquid section depth evidence](liquid-section-depth.md). Their fixes do not resolve coarse shape quantization, liquid transmission ordering, or all noisy boundary cases. This remains a readability foundation, not final high fidelity.

For larger mostly static structures, compare cached chunk surface meshes against opaque ray traversal while retaining volume rendering for gas/liquid. For sparse moving material, reconstruct only affected regions. These are hypotheses: thin features, exposed sections, mesh update latency, overlapping translucent layers, and changing topology must survive the comparison. Dirty regions need more than the brush bounds: smoothing classification has neighbour dependencies, mip parents need updates, sun changes propagate downstream, and hydro/pressure communicate beyond a local halo. The first incremental experiment should isolate geometry and keep global physics intact.

Preserve a narrow contract: material state with stable coordinates/units; transactional edit commands; a fixed-time step; authoritative snapshot/restore; dirty physical bounds; and derived surface/volume/instance outputs. Each output must declare whether it represents conserved material or optional appearance. Never reconstruct authoritative momentum or mass from foam, a normal map, or decorative particles. Selection/picking should consult authoritative boundaries or a documented render-surface query, with predictable tolerance between the two.

## Three viable evolutions

**1. Keep cellular transport, add conservative material fields.** This is the smallest path to richer heat-driven reactions and familiar precise painting. Store transported energy separately from element identity, with material-specific capacity, conductivity, latent heat, and explicit reaction sources. When material swaps or amount moves, transfer its energy consistently; changing temperature alone without accounting for amount/capacity loses that meaning. Charge/connectivity can similarly become explicit state for future electrical construction, with separate network semantics where appropriate.

This direction retains current tests and exact liquid-amount accounting. It cannot deliver inertial sloshing, rigid rotation, or elastic fracture just by adding shader detail or a displayed velocity. Those need a momentum/force model. Global hydro redistribution would also need reconciliation with any future advected momentum; simultaneously applying both without a derivation is not a safe hybrid.

**2. A bounded particle/grid momentum region.** APIC stores a locally affine particle velocity and transfers material to/from a background grid. Its transfer formulation addresses PIC dissipation while preserving linear/angular momentum under its assumptions; it does not by itself supply pressure, collision handling, or every material constitutive law. This makes it a useful liquid-momentum candidate to test rather than a drop-in replacement. [Jiang et al., APIC and accompanying proofs](https://www.disneyanimation.com/publications/the-affine-particle-in-cell-method/), [technical report](https://media.disneyanimation.com/uploads/production/publication_asset/105/asset/apic-tec.pdf).

MLS-MPM extends the particle/grid approach to stress-bearing materials; CPIC addresses cutting/discontinuities and two-way rigid coupling. That research supports a possible later deformable/granular route, not a claim that this game's sand, water, wood, and machinery can all share one cheap solver. [Hu et al., MLS-MPM/CPIC](https://yuanming.taichi.graphics/publication/2018-mlsmpm/).

Storage changes substantially. An illustrative tightly packed 3D MPM particle with position3, velocity3, mass, rest volume, affine matrix9, deformation gradient9, plastic scalar, and material ID is **112 bytes before alignment, sorting, or scratch**. Four particles per occupied cell at 10% occupancy consume about **89.6 MiB at 128 or 716.8 MiB at 256**, additional to a transfer grid and reconstruction. This is an example layout, not a required layout or recommended density. Fluid-only state may omit deformation data. Particles must become authoritative mass carriers; reusing the current 64-byte render transforms does not provide that contract.

Explicit MPM has sound-speed and other stability restrictions; stiffness, collisions, and transfer behaviour affect viable time steps. A 120 Hz game tick can require multiple numerical substeps. Measure a physically meaningful stiffness rather than weakening solids until the benchmark passes. [Sun, Shinar and Schroeder, Effective time step restrictions for explicit MPM simulation](https://onlinelibrary.wiley.com/doi/abs/10.1111/cgf.14101).

**3. Static material plus rigid constructed assemblies.** Connected authored structures could become body-local material/shape data with mass, inertia, constraints, and explicit fracture bonds. Godot already exposes force/impulse-driven rigid bodies and direct integration hooks. It does not automatically couple those bodies to this GPU voxel solver. [Godot RigidBody3D documentation](https://docs.godotengine.org/en/stable/classes/class_rigidbody3d.html).

The hard interface is a moving boundary: voxel/grid occupancy must track the body without deleting displaced liquid, and material forces must return equal-and-opposite impulses. GPU/CPU synchronization and delayed feedback need measurement. Fracture requires a declared model and connectivity update, not only detached render fragments. This direction fits machinery and construction better than simulating every rigid wall as elastic particles, while leaving deformable material experiments possible. Thermal transport across body/world contacts and detached fragments must retain energy. It can coexist with either of the first two directions.

## Experiments that decide the next investment

All candidates use fixed scenes, declared units, fixed simulated duration, captured edit commands, and separate physical metrics from appearance. Proposed frame budgets assume a 60 Hz interactive target; the current milestone has not established that all these features fit simultaneously.

| Experiment | Small bounded implementation | Acceptance / rejection evidence |
|---|---|---|
| Incremental presentation | Frozen 128/256 worlds at 1%, 10%, 50% occupied cells; 100 local paints; incremental fields/mips/sprites against full rebuild. Keep global air/hydro. | Authoritative bytes identical. Derived fields equal within declared quantization, no missing physical instances/cut surfaces. Match normal/coverage probes from this milestone. At 1% activity, target ≥2× reduction in derived GPU time, and report p50/p95, bytes cleared, dirty region growth, and worst sun direction. Reject if reduced averages conceal boundary regressions. |
| Conservative thermal field | 32³ insulated two-material blocks; then a 1D diffusion slab and one melting/boiling interface. Two FP32 energy buffers, no new renderer. | Closed-system relative energy drift <10⁻⁵ over 10 simulated seconds without reactions; no temperature overshoot under the chosen stable step. Compare slab convergence as cell size/time step decrease. Phase change accounts for latent heat; moving liquid carries energy. Tick batching preserves the same solution within declared floating-point tolerance. |
| Momentum candidate | 64³ liquid-only box, force-free rotating material transfer, dam release, slosh, and jet against a wall. Compare current CA with APIC-based fluid or a narrowly scoped MLS-MPM variant. | Force-free transfer relative linear/angular momentum error <10⁻⁴ using nonzero reference momenta. Closed mass drift <0.1% over 10 s; explain any reseeding. Rest-surface RMS <0.25 cell after settling. Show continuing motion after forcing stops, report energy decay and wall leakage. Target solver p95 ≤6 ms on the M5 Pro **including required substeps**; then measure full editor cost before adoption. |
| Rigid coupling | One hinged paddle pushed by water, then a small brittle cantilever with a stated break law. Limit to tens of bodies. | Integrated exchanged impulses balance within 1% when external forces are accounted for. No occupancy overwrite loses liquid. Substep refinement does not reverse motion or radically change break load. Record coupling delay, body count, topology-update cost, physical mass ledger, and Build→Run→Return restoration. |

The energy gate is a numerical reference test, not a request to make fire obey an unspecified real-world chemistry model. Likewise a visually pleasing dam break is insufficient evidence for the momentum gate. Record unachieved criteria rather than silently relaxing stiffness, removing material, lowering output resolution, or excluding costly coupling passes.

Run the geometry-cost experiment and conservative thermal reference independently. Run one momentum candidate against the current solver before expanding materials. Only begin rigid coupling after agreeing the moving-boundary/mass-exchange contract; otherwise each solver can look correct in isolation while their composition creates or destroys material. The editor's paint, region, undo, and authored/live-state interfaces should continue to work throughout these experiments.

No production solver, physical state, dependencies, or renderer were changed for this brief. Validation performed: source inventory, primary-source review, and execution of the standard-library allocation calculator at 128/256/512 against both the rendering and integration checkouts. Those checks establish the stated arithmetic and source observations; they do not establish real-time feasibility of any proposed solver.
