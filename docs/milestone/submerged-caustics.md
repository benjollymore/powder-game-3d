# The lattice on submerged surfaces

Ben reported "weird graphical bugs": a regular, axis-aligned lattice of
near-white marks over water, with normal water visible between them. He gave
three repros, which is what solved it:

1. molten wax on top of water,
2. lava under water as it turns to stone,
3. solid wax viewed from underwater.

Two earlier investigations failed to reproduce it and disproved two
hypotheses along the way. Neither the thin-liquid rescue nor submerged leaf
cards is involved: a previous measurement established that the bright bars are
*added* structure on otherwise normal water, not missing liquid, and submerged
plant grows no leaves at all. What the three repros share is not a material or
a film. It is a **surface seen through liquid**.

## Cause

`shaders/spatial/voxel_opaque.gdshader` brightens a cell that lies under a
liquid with a sun-projected caustic ripple. The ripple's position comes from
projecting the shading point along the sun onto the `y = 0` plane and sampling
two octaves of noise by the resulting `xz`:

```glsl
vec3 q = ps - to_sun_model * (ps.y / max(abs(to_sun_model.y), 0.3));
float c1 = texture(grain_noise, vec3(q.xz / 9.0, sim_time * 0.35)).r;
```

That is a reasonable model for a floor. It degenerates on anything else,
because the strength was applied **whatever way the surface faced**. On a
vertical face every point shares nearly the same `xz`, so as the point moves
down the face the sample walks a straight line through the noise, and the
two-dimensional ripple collapses into stripes. Along a voxel staircase those
stripes land cell by cell, which is the lattice Ben saw, and the multiplier
reaches `0.6 + 2.6 * c`, up to 3.2 times the sunlight, which is why the marks
read as near-white.

This fires on any submerged surface at any orientation, from above or below,
solid or liquid film, which is why all three of his repros show it and why
fixtures built from films alone never did.

## Fix

Caustics are sunlight focused by the surface overhead onto what lies below, so
their strength follows the receiver's cosine like any other irradiance. The
ripple is now scaled by `max(dot(n_geo, to_sun_model), 0.0)`. A submerged wall
takes almost none, a submerged floor takes it all. Nothing else changed: the
projection, the noise, the opacity falloff and the tint are untouched.

## Evidence

Loaded from Ben's own `construction.p3d` (a wall floor, water at y 4..11, a
stone block through it, lava on top), captured from inside the water:

| | `ben-save/` |
| --- | --- |
| his frame, striped submerged stone | `before-his-frame.png` |
| the same frame with caustics off, the control | `caustics-off-control.png` |
| the same frame with the fix | `after-fix.png` |

The fixed capture matches the caustics-off control on the submerged face while
lava, the dry stone above the waterline and the water itself are unchanged.

`tests/milestone/submerged_caustic_gpu.gd` (`submerged-caustic128`) gates both
halves of the contract against a pinned pre-change shader, measuring how much
pattern each variant adds over the same frame with caustics off:

| case | pinned shader | with the fix |
| --- | ---: | ---: |
| submerged wall | 0.02101 | 0.00810 |
| submerged floor | 0.02948 | 0.02664 |

The wall keeps a residual and should: a voxel staircase genuinely has partly
upward-facing facets, and those receive caustics correctly. What goes is the
stripe pattern, which the matched captures show. The floor control exists so
the fix cannot pass by simply deleting the effect. Both cases assert the
physical bytes are unchanged.

Three suites pin their own copy of the opaque shader to isolate an unrelated
variable (palette width, per-liquid opacity, the examples look). Each was
synced with this one-line change so it still isolates only its own variable,
the same treatment the leaf-exposure fix applied.

## Suites

`submerged-caustic128` 7 checks, and `physics128`, `palette128`,
`liquid-base128`, `examples-look128`, `liquid-render128`, `liquid-edges128`,
`ordinary-interface128`, `ordinary-geometry128`, `ordinary-controls128`,
`capacity128`, `surfaces-render128`, `sprites-render128`, `ripple128`,
`leaf-exposure128`, plus all 31 CPU suites.

## Limits

The caustic pattern is still a screen-space-ish approximation projected along
the sun, not refracted light, and it is still sampled per fragment rather than
accumulated through the liquid. A surface that faces the sun but sits under a
deep body of water gets the same ripple strength as one just below the
surface; depth is not part of the term. Those are pre-existing properties of
the effect, unchanged here.
