# Bright streaks at the base of frozen liquid blocks

Status: cause established from the captures and the shader source; corrective shader change drafted with an A/B suite and a paired cost fixture. GPU validation pending the lease. No physical bytes, compute kernels, or authoritative state change.

The palette capture suite showed sparse bright vertical streaks along the lower part of every frozen lava and acid block standing on a wall slab, first read as droplet proxies hanging off the bottom edge.

## Cause

The blocks are uploaded with a zero flag byte and never ticked, and the suite's byte-identity checks proved the readback equals the upload, so no cell carries the falling bit. Both `thin_spray()` in `voxel_volume.gdshader` and the droplet layer in `splat_emit.glsl` require that bit; neither can run on this fixture. The `ordinary_thin()` slab proxy needs air on both sides of an axis, which no cell of a full block on a slab has.

Luminance profiles of the acid and lava captures against the slab-only capture put every streak inside the block's projected footprint, in its lower half, not below it. That region is the slab surface seen through the liquid. `voxel_opaque.gdshader` brightens slab cells whose upper neighbour is liquid by `mix(1, 0.6 + 2.6 c, caustic_strength)`, a sparse sun-projected ripple pattern meant for water, and the volume pass attenuates every liquid with the same global `absorb`, so lava is nearly as clear as water and shows the ripples through its body. The frozen `sim_time` makes the pattern static, so it reads as spikes.

## Correction

A per-element `liquid_opacity[32]` uniform (row key `opacity`, default 1) multiplies `absorb` for the liquid being traversed in the volume pass, and the opaque pass divides `caustic_strength` by the opacity of the liquid above. Water and every existing liquid keep opacity 1, so their arithmetic multiplies by exactly 1.0 and the output is byte-identical. Lava (12), molten wax (5) and acid (2) become dense enough to hide what they cover and cast no water ripples. This is a presentation contract for translucency, not fluid physics.

## Validation (pending lease)

`tests/milestone/render_liquid_base_gpu.gd`: water and lava blocks on a slab, front and oblique, baseline shaders versus current, each with caustics on and off. Gates: no falling flags in the block; water byte-identical in both caustic states; lava baseline streak count with caustics at least three times the count without (diagnosis); lava candidate at the no-caustic level with caustics on and insensitive to `caustic_strength`; physical bytes unchanged. Streaks are pixels in the lower half of the block's screen box brighter than that band's median by 0.12.

`tests/milestone/liquid_base_cost.gd`: 256 reservoir of water then lava, paired baseline/candidate medians three times each, with capture byte comparison (water must be identical).

```sh
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_liquid_base_gpu.gd -- grid=128 output_dir=/tmp/rendering-gpu/liquid-base128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/liquid_base_cost.gd -- grid=256 output_dir=/tmp/rendering-gpu/liquid-base-cost256
```
