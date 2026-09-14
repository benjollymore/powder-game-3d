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

`sprites=0` and `fx=0` on the command line disable the layers for benchmarks;
`hide=<grains|leaves|droplets|fx>` skips drawing one layer.

### Water: refraction, froth, caustics

`fields.glsl` keeps a froth channel (A): 1 where liquid is falling or just
landed (byte A bits 0-2), averaged over same-layer neighbours and decaying
by 7% per update so it lingers briefly after the water calms. The volume
pass whitens the liquid surface and interior by it (matte, mostly opaque), so
pours and impacts read as aerated water. Rays that cross a liquid surface
compose the backdrop themselves: they sample the screen texture shifted along
the entry normal (scaled by the path length through liquid, and falling back
to the unshifted pixel when the shifted one holds nearer geometry) instead of
relying on alpha blending, so sand and walls behind water refract. The opaque
pass detects a liquid cell just outside the hit surface and modulates direct
sunlight with two drifting octaves of noise projected along the sun (a
caustic pattern animated by simulation time) and tints the albedo blue-green.

Two details keep this calm: a liquid surface whose cell has no liquid under
it is a thin film (rain on a wall, a wet floor), and its reflection, highlight
and refraction are scaled by the cell's fill so grazing views of lumpy
one-cell sheets do not turn into bright contour bands; and a ray passing from
one liquid into another (oil floating on water) closes the first segment in
its own colour and starts a new one, so a thin oil film no longer tints the
whole pool beneath it. Scenario pools are authored to rest on their bowl
floors: a one-cell air gap under a pool becomes bubbles that keep the whole
surface frothy for a long time.

`p:name=value` on the command line sets a float shader parameter on every
material at boot (`p:foam_strength=0`, `p:refraction=0`,
`p:caustic_strength=0`), for isolating a feature in a screenshot or bench.

### Anti-aliasing, exposure, motion blur

The viewport renders at 0.75 scale through MetalFX spatial upscaling with
FXAA. MetalFX temporal (and any TAA) was measured and rejected: the sprite
layers are MultiMesh instances whose transforms are written on the GPU, so
Godot has no motion vectors for them, and grains, droplets and embers ghost
into soft blobs; SMAA costs about 2 ms more than FXAA for a small edge gain.
`aa=fxaa|smaa|temporal|spatial|off` on the tools switches modes for
comparison (`tools/screenshot.gd`, `tools/bench.gd`), and `spin=deg` orbits
the camera per frame so temporal artifacts show in a still.

Auto exposure was tried and left off by default: with the pale sky and white
plane the metering brightens the open scene toward its target grey and blows
out the ground, and the fire close-up gains little. `exposure=1` enables it
(sensitivity window 90–180) for comparison.

Camera motion blur is a post-transparent CompositorEffect
(`scripts/environment/motion_blur.gd`, `shaders/post/motion_blur.glsl`) that
needs no motion vectors: each pixel's depth is unprojected to a world point
and reprojected with the previous frame's view-projection, giving exact
velocities for the static voxel world (the raymarch writes its own depth, so
Godot's vectors would be the bounding cube's) and the camera's blur for
sprites. Eight taps along the velocity, clamped to 16 internal pixels,
weighted down where the tap's depth differs from the pixel's. Two dispatches
(blur into a scratch buffer, copy back) because the colour buffer cannot be
copied or read while written. `mblur=0` disables it, `mblur=2` shows the
velocity field.

Crisp surfaces (walls, `smooth` 0) take their face normal from the voxel
plane nearest the bisected hit rather than the DDA's last step axis: the 0.5
crossing of a crisp field sits exactly on the face, so the step that detects
it can come from either side and the step axis is unreliable there (it
produced moiré on tank walls).

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
