# Voxel format

The world is a 128³ RGBA8 3D texture living on Godot's global RenderingDevice.
Each voxel is four bytes, read and written as exact integers (unorm8 round-trips
0–255 losslessly):

| Byte | Meaning |
|---|---|
| R | element id (`Elements.Id`, 0 = air) |
| G | per-voxel random seed: colour variation now, rule randomness later. Travels with the grain when it moves. |
| B | liquid amount, 0 for anything that is not a liquid. `Elements.LIQUID_FULL` (200) is a nominal full cell; deeper cells hold up to 255 as hydrostatic compression |
| A | bit 0: the liquid is in an unsupported (falling) run, set by `hydro.glsl`; other bits reserved |

Why RGBA8 and not R32_UINT: the renderer samples the same texture through
`Texture3DRD`, which only accepts RenderingDevice formats that map to an
`Image` format. No integer formats do; RGBA8 does.

Coordinates: x fastest, then y, then z (`VoxelCodec.index`). The unit cube mesh
at the origin maps model space `[-0.5, 0.5]³` to voxel space `[0, 128)³`, so
voxel `(x, y, z)` is centred at `((x, y, z) + 0.5) / 128 - 0.5`. Reads outside
the box return wall, writes outside are dropped, which gives the world a floor
and walls for free.

Single source of truth for element ids, colours, densities and flags:
`scripts/sim/elements.gd`. Both compute shaders and the raymarcher derive
everything from it (property buffer, reaction buffer, palette, UI).

## Occupancy grid

A 16³ R8 texture, one texel per 8³ brick, holds 1 where the brick contains
anything that is not air or gas. It is rebuilt by `shaders/compute/occupancy.glsl`
after every tick batch, brush stroke, upload and clear. The raymarcher leaps
across empty bricks, and `scripts/sim/shadow_proxy.gd` reads it back
asynchronously to place shadow-only cubes so the voxel mass casts a shadow on
the ground without re-running the raymarch in the shadow pass.

## Density field

A 128³ R8 texture written by `shaders/compute/density.glsl` after every
change: 0 for air and gases, 1 for solids and powders, and for liquids a remap
of the fill level chosen so that trilinear sampling puts the 0.5 crossing
exactly `fill` of the way up a partial cell resting on a full one. The
raymarcher draws liquids as that isosurface.
