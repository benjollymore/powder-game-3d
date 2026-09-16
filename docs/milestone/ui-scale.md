# The sidebar scales with the window

The paint editor's sidebar was authored in fixed pixels: a 390 px panel, 16 px
text, a 90 px speed label, a 300 px status. That is why a whole unit went into
squeezing it back inside 1280×800, and why it reads as a postage stamp on a
large display. It now scales with the window.

## What was chosen, and what was rejected

**Chosen: scale the 2D theme, leave the viewport alone.** A factor is derived
from the window, applied to the theme's default font size and to the sidebar's
own geometry, and reapplied whenever the window resizes.
[`scripts/editor/ui_scale.gd`](../../scripts/editor/ui_scale.gd) holds the
arithmetic; the editor calls it from `size_changed`.

**Rejected: Godot's own content scaling.** `Window.content_scale_factor` was
measured before choosing, on a 1600×900 window with a `Camera3D`:

| | `size` | `get_visible_rect()` | ray at pixel (800, 450) |
| --- | --- | --- | --- |
| factor 1.0 | 1600×900 | 1600×900 | (0, 0, −1), the screen centre |
| factor 2.0 | 1600×900 | 800×450 | (0.73, −0.41, −0.54) |

Two things break. The visible rect halves, so the raymarched view would render
at a quarter of the pixels and fight the Sharper/Faster picture preference,
which owns `scaling_3d_scale` and is the only thing that should decide 3D
resolution. And canvas coordinates stop matching real pixels, while the editor
feeds `get_viewport().get_mouse_position()` straight into
`Camera3D.project_ray_*`: at factor 2 the screen centre projects as the
bottom-right corner, so every pick and every stroke would land away from the
pointer. Scaling the theme instead leaves the viewport pixel-exact, 3D
resolution untouched, and the input path in real pixels.

## The factor

`min(width / 1600, height / 900)`, clamped to `[0.7, 3.0]`. Both axes matter: a
wide but short window must still shrink the sidebar, or the status pinned below
the scrolling controls falls off the bottom. At the project's default 1600×900
the factor is exactly 1.0, so the authored layout is reproduced unchanged and
every existing layout check measures what it always did. The upper clamp stops a
6K display from turning the sidebar into a wall.

The panel is never narrower than its own controls need. On a small window the
content's combined minimum can exceed the scaled target, and forcing the panel
below it would clip rows rather than shrink them.

## Scaling the editor's own theme, not a second one

`interaction_lab` builds the sidebar and then, on the next line,
`editor_theme.apply(tools_panel)` replaces the panel's theme with its own
(`default_font_size = 15`). A theme created during `_build_ui` is therefore
orphaned a moment later, and every control keeps resolving 15 px however the
window changes: in the real editor the sidebar measured 413 px at 1280x800
against an authored 390, and the containers' minimum widths did not move by a
single pixel across three window sizes. The scale is applied to whichever theme
is attached, adopted after `editor_theme` has run, so there is exactly one.

The test labs build the UI without attaching any theme, so the editor supplies a
bare one when it finds none. That keeps the headless fixture and the real scene
on the same path.

## One subtlety worth keeping

A `Control` silently clamps an assigned `size` to its children's combined
minimum, and after a font change those minimums still hold the previous font's
values for a frame or more. Shrinking a window therefore left the sidebar stuck
at the width the larger font had needed. `_settle_ui_scale()` re-asserts the
target every frame until the controls have re-measured; it assigns only when the
value actually differs.

## Evidence

`tests/milestone/ui_scale.gd` (CPU, 39 checks) builds the real editor UI over
the paint-tools stub simulator and resizes the window under it, so it covers the
live `size_changed` path rather than the arithmetic alone. Measured:

| window | sidebar | font |
| --- | ---: | ---: |
| 1100×700 | 273 px | 11 |
| 1280×800 | 312 px | 12 |
| 1600×900 | 390 px | 15 |
| 2560×1440 | 624 px | 25 |
| 6016×3384 | 1170 px | 45 |

The real editor scene carries rows the fixture does not (the archive panel, the
heat row, the tool row), so its content minimum is wider and the sidebar bottoms
out there rather than at the factor's target:

| window | sidebar | font |
| --- | ---: | ---: |
| 1100×700 | 347 px | 11 |
| 1280×800 | 354 px | 12 |
| 1600×900 | 405 px | 15 |
| 2240×1260 | 546 px | 21 |

At every size the sidebar fits the window, keeps the pinned status inside
itself, stays at least as wide as its controls need, and leaves at least 55% of
the window to the world. Returning to 1600×900 restores the authored 390 px and
16 px exactly.

`tests/milestone/ui_scale_gpu.gd` runs one fixed drag, authored in world cells,
at 1600×900, 1280×800 and 2240×1260, and requires the changed cell set to be
identical at all three: the sidebar resizes, the pointer does not. It also
asserts the visible rect still equals the window at each size, which is the
property `content_scale_factor` would have broken.
