# Simulation rules

`shaders/compute/sim.glsl` runs one tick as a **Margolus block cellular
automaton**: the grid is cut into 2×2×2 blocks, one GPU thread owns one block and
only touches its own 8 cells. Every rule is a swap or an in-place transmute, so
there are no write hazards and mass is conserved by construction. The partition
offset changes each tick (hashed, one of 8), and each block picks a random
horizontal mirror/swap, so no direction is favoured and no checkerboard shows.

Rules run in this order inside a block (canonical frame, y up):

1. **Reactions** — for each of the 12 axis-adjacent pairs, the first matching
   row of `Elements.REACTIONS` fires with its probability (scaled by fill for a
   liquid participant) and replaces both cells. MVP: fire+plant → fire+fire,
   fire+oil → fire+fire, fire+water → air+steam, plant+water → plant+plant.
2. **Decay** — a cell with `decay > 0` turns into its `decay_to` with that
   probability per tick. Fire → smoke, smoke → air (slowly), steam → water
   (very slowly, so it rains).
3. **Vertical** — in each of the 4 columns: if both cells are air or the same
   liquid, the liquid *amount* is split hydrostatically (see below); otherwise
   if the top cell is denser than the bottom and neither is immovable, swap.
   One comparison covers falling (sand, water) and rising (steam, fire, oil
   under water).
4. **Powder slump** — a powder that could not fall tries, with 50% chance, a
   random other column's bottom cell; if that is lighter, swap diagonally. This
   forms piles at a natural angle.
5. **Liquid spread** — on each row of the block, one liquid pools its amount
   with same-liquid cells (and, on the top row, with air cells, if the liquid is
   resting on something) and splits it evenly. Tiny remnants join a neighbour.
6. **Vertical again** for liquids, so water that spread over an edge falls the
   same tick.
7. **Wind** — cells drift with the coarse air velocity sampled at the block
   centre, moving to the downwind partner when it is air or gas, with a chance
   proportional to the velocity and the element's `air_coupling` (gases 1,
   liquids 0.1, sand 0.05).
8. **Gas spread** — gases on the bottom row drift into a random same-layer gas
   neighbour, which diffuses clouds.

Only cells that changed are written back.

## Liquid amounts and pressure

Byte B of a liquid cell is its amount: `FULL` = 200 is a nominal full cell and
cells deeper in a column hold up to 255 as compression (`COMP` = 2 extra units
per cell of liquid above). A column of two cells with total S rests with the
bottom holding `stable_bottom(S)`: all of it below FULL, then a blend up to
FULL+COMP, then half plus COMP. Rounding is stochastic so tanks and 1-wide
pipes agree on pressure.

Pairwise splitting inside blocks only moves pressure at diffusion speed, so
`shaders/compute/hydro.glsl` runs after every tick with one thread per grid
line: columns get the exact hydrostatic profile within each contiguous run of
one liquid (never across air, so falling water still falls cell by cell), and
rows along x or z (alternating each tick) relax toward the run's mean by 50%.
That is what makes water find its level through a U-bend and climb a pipe to
the height of the tank feeding it. The column pass also flags runs that are not
resting on anything (byte A bit 0) so falling water holds together instead of
spraying sideways.

Timing: TimeController hands the sim 0–8 ticks per frame (180 ticks/s at real
time). A cell pairs with the cell below it on about half of all ticks, so a
free-falling grain moves ~90 voxels per second.

Tests for each rule live in `tests/gpu/run_gpu_tests.gd`.

## Air solver

`shaders/compute/air/` holds a coarse Eulerian air simulation on a 32³ grid
(4³ voxels per cell), run once per tick batch before the Margolus ticks:
downsample (solid fraction from walls, powders and liquid fill; heat from fire,
steam and smoke) → semi-Lagrangian advection of velocity and heat with
buoyancy, drag and a speed clamp → divergence → 20 Jacobi iterations of the
pressure Poisson equation with Neumann walls → projection that also zeroes flow
into solids. The resulting velocity field (voxels per tick) feeds the wind rule,
so fire makes convection plumes that mushroom at the ceiling and recirculate.
Velocity and pressure are cleared on upload and clear, and the whole run is
deterministic from a given upload.

## Rendering

Two raymarch passes share `shaders/spatial/voxel_dda.gdshaderinc` and read the
voxel texture plus the renderer fields written by `shaders/compute/fields.glsl`
(R liquid density smoothed across same-liquid neighbours, G opaque density
blurred by a 3³ kernel weighted by each element's `smooth`, B gas, with a mip
chain from `fields_mip.glsl`) and a two-channel occupancy grid (solids /
fluids per 8³ brick) for empty-space leaps.

`voxel_opaque.gdshader` is a lit, opaque material: it finds the 0.5 isosurface
of the smoothed field (walls stay crisp cubes at smooth 0, sand becomes a heap
at 1), shades it with triplanar textures from `scripts/render/material_library.gd`,
a grain normal, cone-traced ambient occlusion from the field mips and curvature
darkening, and hands Godot a normal, roughness, AO and the hit position, so sky
ambient, specular, fog, depth of field and glow come from the engine. Its
`light()` multiplies direct sunlight by the sun-visibility field.

`voxel_volume.gdshader` draws liquids (0.5 isosurface of the liquid field with
Fresnel, sun highlight, in-scattering and Beer-Lambert absorption) and gases
(participating media lit through the sun-visibility field) with premultiplied
alpha, stopping at the opaque pass's depth so it never re-marches solids.

`shaders/compute/sunvis.glsl` sweeps a half-resolution sun-visibility field
slab by slab from the sun-facing face (16×16 tiles walking 8 slabs with a
haloed shared-memory copy of the previous slab), rebuilt whenever the world
changes. It shadows sand under smoke, pits, and the ground plane: the ground
shader intersects each point's ray toward the sun with the box and samples
the field where it enters, giving a voxel-accurate shadow with no shadow map.

Powder cells carry a "moved age" (byte A bits 1-2, set to 3 when a grain
moves and counting down at rest); liquid cells use the same bits as a "landed
age", set by `hydro.glsl` the tick a falling run comes to rest. After every
world change `shaders/compute/splat_emit.glsl` walks the occupied bricks and
fills MultiMesh instance buffers on the GPU (`scripts/render/instance_layer.gd`,
one node per layer under SimVolume; the CPU never touches the instances):

- **Grains** (`splat.gdshader`): powders that moved recently with nothing
  under them. `fields.glsl` leaves them out of the heap surface, so poured
  sand reads as a curtain of lit, camera-facing grain sprites and a settled
  pile emits none.
- **Leaves** (`leaf.gdshader`): every plant cell (`FLAG_LEAFY`) exposed to
  air grows a leaf card oriented outward and tilted by its seed, unless it
  sits in a vertical run of plant at least GRID/8 tall (bark). Cards are
  two-sided with a back-light term, sway with simulation time, and cover the
  smoothed green surface underneath. Trees are wood trunks with canopies of
  overlapping plant spheres, and a one-cell plant layer reads as grass.
- **Droplets** (`droplet.gdshader`): falling liquid cells with at most two
  liquid face neighbours are thin spray; the fields pass drops them from the
  liquid surface and they draw as blended glossy beads after the volume pass.
- **FX pool** (`fx.glsl`, `fx.gdshader`): a persistent buffer of 32k
  particles stepped once per frame by simulation time (frozen time freezes
  them). The emit pass queues spawn requests (embers off exposed fire, dust
  where grains land, a ring of splash droplets where liquid lands); dead slots
  claim them. Particles follow the air velocity field with per-kind buoyancy,
  drag and flutter, die against the smoothed opaque field (dust settles on
  it), and draw as unshaded soft discs: embers emissive so they bloom, dust
  and splash lit by sun visibility.

`sprites=0` and `fx=0` on the command line disable the layers for benchmarks.

The depth prepass is disabled: an opaque material that writes depth would run
the raymarch twice, and the voxel AO covers what SSAO provided. `debug=N`
shows flat colour (1), AO (2), normals (3), texture (4) or sun visibility
(5); `vdebug=N` on the volume pass ignores depth (1), shows the depth stop
(2) or liquid diagnostics (3).

## Scenarios

`scripts/scenarios/scenarios.gd` authors presets in a 128-voxel reference box
as a list of box and sphere fills, scaled to the real grid. The sim replays the
list on the GPU through the brush kernel's box mode (`load_scenario`), so a
256³ world loads without a CPU voxel loop; `Scenarios.build` replays the same
list on the CPU for tests.
