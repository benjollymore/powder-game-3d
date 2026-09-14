# Readable surfaces for overflow water

The first [capacity correction](material-capacity.md) gave every overflow droplet an amount-aware box, but bulk absorption/scattering alone made those boxes too faint. This followup adds a reflective interface only to overflow water proxies. Their geometry, amounts, optical path lengths, sprite eligibility and whole-layer capacity decision stay unchanged.

Compare the same 100 quarter-full water cells under the same camera and light:

| Bulk optics only | With a water interface | Original under-capacity sprites |
|---|---|---|
| [Before](material-interface-evidence/off/small-droplets-capped.png) | [After](material-interface-evidence/on/small-droplets-capped.png) | [Droplets](material-interface-evidence/on/small-droplets-enough-capacity.png) |

The result is visibly clearer, with reflective gray-blue boxes. The round highlighted droplets remain the preferable detailed representation. This does not resolve the conspicuous whole-layer shape change or lattice when capacity is crossed; it is a bounded emergency fallback, not the final budget architecture.

The proxy entry normal comes from the ray-box slab intersection. At an actual air-to-water entry, the shader uses the existing liquid Fresnel constant, hemispherical sky color and sun highlight. It attenuates transmitted light by the Fresnel fraction before the unchanged amount-aware bulk integration. It does not add proxy refraction, foam, a global palette change, or new physics state.

Reflection is suppressed when the ray starts inside a proxy, enters through an artificial section cap, continues through touching proxies, or is stopped by opaque geometry before reaching the proxy. An interval history within the fragment avoids adding a second surface where liquid intervals touch; a physical full-cell neighbor check also excludes known interior faces. A partial proxy separated from the section plane by air still has its real reflective surface. `proxy_surface_reflection=false` is a diagnostic A/B control affecting only this overflow interface.

The **66-check GPU gate suite passed** with reflection on/off, inside/outside cameras, all three full-cell section axes, a partial cell inside a cutaway, touching and separated proxies, an opaque blocker, and a removed cell. The suite includes an ordinary-liquid-to-proxy join. That new case initially caught a false reflection. Retaining density-exit history alone did not fix it: the legacy marcher can miss an isolated full ordinary-liquid cell, so no ordinary segment opens. The final guard additionally checks physical full-cell adjacency, suppressing the false air/water interface without altering ordinary geometry. Both failed gate logs remain in the evidence folder. The 145-check analytic geometry suite also passed: 212,186 water ray probes and 84,314 opaque coverage probes, with unchanged maximum optical-length error 0.01125 cells against the declared 0.035 tolerance. Both lit capture runs passed 83 checks covering exact voxel bytes, air textures, legacy under-capacity records/fields, and recovery/reset.

Evidence is retained in [gate results](material-interface-evidence/gates/regression.json), [analytic geometry results](material-interface-evidence/geometry/regression.json), and [reflection-off](material-interface-evidence/off/visual.json)/[reflection-on](material-interface-evidence/on/visual.json) visual records. Their water voxel SHA-256 hashes match. Previous evidence remains intact.

```sh
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_proxy_interface_gpu.gd -- grid=128
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_proxy_geometry_gpu.gd -- grid=128 output_dir=res://docs/milestone/material-interface-evidence/geometry
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_capacity_gpu.gd -- grid=128 visual_only=1 no_proxy_reflection=1 output_dir=res://docs/milestone/material-interface-evidence/off
godot --path . --always-on-top --disable-vsync -s res://tests/milestone/material_capacity_gpu.gd -- grid=128 visual_only=1 output_dir=res://docs/milestone/material-interface-evidence/on
```

These are native-resolution, spatial-AA-disabled diagnostic captures on Godot 4.6.3 / Apple M5 Pro / Metal. The interface adds no allocations or compute dispatches. Its additional fragment cost was not measured; the earlier capacity-preparation timing still describes the unchanged compute work, not an interface-specific timing result. Very small/distant proxies can remain subpixel. The guard for ordinary neighbors intentionally uses full cells; partial-film interfaces still depend on the existing density representation. The sky approximation and box shape are coarse presentation choices, and no claim of high-fidelity liquid physics follows.
