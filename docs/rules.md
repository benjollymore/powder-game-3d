# Simulation rules

`shaders/compute/sim.glsl` runs one tick as a **Margolus block cellular
automaton**: the grid is cut into 2×2×2 blocks, one GPU thread owns one block and
only touches its own 8 cells. Every rule is a swap or an in-place transmute, so
there are no write hazards and mass is conserved by construction. The partition
offset changes each tick (hashed, one of 8), and each block picks a random
horizontal mirror/swap, so no direction is favoured and no checkerboard shows.

Rules run in this order inside a block (canonical frame, y up):

1. **Reactions** — for each of the 12 axis-adjacent pairs, the first matching
   row of `Elements.REACTIONS` fires with its probability and replaces both
   cells. MVP: fire+plant → fire+fire, fire+oil → fire+fire,
   fire+water → air+steam, plant+water → plant+plant.
2. **Decay** — a cell with `decay > 0` turns into its `decay_to` with that
   probability per tick. Fire → air, steam → water (slow, so it rains).
3. **Vertical** — in each of the 4 columns, if the top cell is denser than the
   bottom and neither is immovable, swap. One comparison covers falling (sand,
   water) and rising (steam, fire, oil under water).
4. **Powder slump** — a powder that could not fall tries, with 50% chance, a
   random other column's bottom cell; if that is lighter, swap diagonally. This
   forms piles at a natural angle.
5. **Fluid spread** — liquids on the block's top row (so their cell below is
   known and supporting) and gases on the bottom row (cell above known and
   blocking) drift, with `spread` probability, into a random same-layer
   neighbour: liquids into anything lighter, gases into any other gas. Falling
   water therefore does not spray, and puddles level out.

Only cells that changed are written back.

Timing: TimeController hands the sim 0–4 ticks per frame (60 ticks/s at real
time). A cell pairs with the cell below it on about half of all ticks, so a
free-falling grain moves ~30 voxels per second.

Tests for each rule live in `tests/gpu/run_gpu_tests.gd`.
