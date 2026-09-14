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

`shaders/spatial/voxel_raymarch.gdshader` walks the voxel texture per pixel.
Solids and powders are opaque lit cubes. Liquids are drawn as the 0.5
isosurface of the density texture written by `shaders/compute/density.glsl`
(trilinear, so partial cells give a smooth surface at the right height), with
Fresnel reflection of the sky, a sun highlight, in-scattering in the liquid's
palette colour and Beer-Lambert absorption of whatever lies behind. Gases
(steam, fire, smoke) are participating media accumulated along the ray using
each element's `extinction`; fire also carries `emission` so it blooms. The
material is transparent with premultiplied alpha, so the ground and sky show
through water and gas at the box faces, and it writes depth at the first
surface so other meshes composite correctly.
