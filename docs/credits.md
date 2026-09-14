# Credits

Powder Game 3D is built with [Godot Engine](https://godotengine.org) 4.6
(MIT licence). It ships no third-party art or audio:

- **Textures**: procedural. `scripts/render/material_library.gd` builds the
  triplanar albedo and normal layers (stone, sand, plant, generic, wood) from
  seamless simplex noise at boot, and a 3D noise texture supplies grain and
  the underwater caustic pattern.
- **Sprites**: procedural. Grains, leaves, droplets, embers, dust and splash
  are shaded shapes (discs, a leaf outline with midrib and veins), not images.
- **Audio**: procedural. `scripts/audio/soundscape.gd` synthesises the wind
  bed, water, fire and steam from filtered noise, bubble chirps and crackle
  impulses at runtime through `AudioStreamGenerator`.
- **Sky and lighting**: Godot's `ProceduralSkyMaterial`, directional sun and
  the project's own voxel sun-visibility field.

Inspiration: Powder Game (ha55ii / DAN-BALL) and The Powder Toy for the
falling-sand genre; Besiege and Totally Accurate Battle Simulator for the
pale-plane, tilt-shift sandbox look.

If CC0 assets are added later (ambientCG textures, freesound loops), list
them here with author and licence.
