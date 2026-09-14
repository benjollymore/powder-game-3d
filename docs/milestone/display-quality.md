# Editor picture quality

The editor now starts with full-resolution 3D and FXAA, making geometry edges clearer than the previous 0.75-scale bilinear image. Tools & view options contains a Picture selector: **Sharper** uses this new default, and **Faster** restores the earlier 0.75-scale bilinear path. Both retain FXAA. Selection is saved in `user://editor_preferences.cfg`; invalid saved values fall back to Sharper. This changes picture resolution only, never cell size, simulation grid, paint radius or physical state. An explicit selection ends the current brush gesture before changing the view.

## What the comparison showed

The fixed 128³ Demo specimen was captured at 1600×900 in front and angled views, with physical bytes verified unchanged. [Capture settings](quality-evidence/captures.json) and [raw log](quality-evidence/run.log) record the actual viewport mode. Compare [previous default](quality-evidence/angle-default.png), [explicit MetalFX spatial](quality-evidence/angle-metalfx-fxaa.png), [native FXAA](quality-evidence/angle-native-fxaa.png), and [native SMAA](quality-evidence/angle-native-smaa.png).

Visual inspection found native FXAA clearer along rigid edges without the stronger sharpening/noise of the explicit MetalFX capture. SMAA retains more small edge discontinuities in this specimen. These are judgments about these still images, not an objective perceptual score or proof of stability during motion. Native resolution does not fix voxel-shaped silhouettes, coarse reconstruction, transparency ordering, or the remaining material appearance work.

A configuration trap was exposed: the base project requests scaling mode 3 (MetalFX spatial), but Godot 4.6.3 registers a macOS override of mode 0. In this process, `get_setting` returned 3, `get_setting_with_override` returned 0, and the visible root viewport reported 0. Its default image therefore used bilinear scaling. Godot initializes viewport scaling from the effective project settings in its [viewport constructor](https://github.com/godotengine/godot/blob/4.6.3-stable/scene/main/viewport.cpp#L4972). The editor preference explicitly sets the intended portable mode. An earlier liquid-stage report has been corrected rather than treating its captures as MetalFX evidence.

## Cost in an active larger scene

Three separate 20-second ordinary-scheduler runs of the 256³ Dam break fixture used 1600×900, VSync enabled, a cutaway and the standard editor process loops. They were executed serially on Godot 4.6.3 / Metal / Apple M5 Pro. No fixed tick count was forced per frame.

| Profile | Mean / p95 frame interval | Average rendered frames/s | Achieved simulation ticks/s |
|---|---:|---:|---:|
| Previous 0.75 bilinear + FXAA |11.199 /15.267 ms|89.3|120.045|
| Native + FXAA |12.059 /15.766 ms|82.9|120.211|
| Explicit 0.75 MetalFX spatial + FXAA |11.392 /15.390 ms|87.8|119.973|

All runs restored exact authored bytes and had zero frames at the scheduler cap. The native run costs about 0.86ms more mean frame interval than the earlier baseline here, while meeting the 120-tick/s target. These are unpaired single runs with ordinary scheduling and presentation noise; they do not establish a universal 7% cost or isolated GPU pass timings. [Native results and command](soak-native-fxaa/results.json), [MetalFX results](soak-metalfx-fxaa/results.json), [baseline and other fixtures](editor-scheduling.md).

The eight comparison images and these three timings precede the preference helper itself. Their explicit viewport configurations establish the tradeoff used to choose the new default. Existing historical measurements retain their original 0.75-scale conditions; they must not be relabeled as timings of the new default.

## Reproduction

```sh
godot --path . --always-on-top --disable-vsync --resolution 1600x900 -s res://tools/milestone/capture_quality.gd -- grid=128 output_dir=/tmp/powder-quality
python3 tools/milestone/run_editor_soak.py --grids 256 --scenarios 'Dam break' --seconds 20 --quality native-fxaa
```

The soak tool defaults to the editor's selected preference. `--quality project` preserves the effective project-file profile, while explicit native/MetalFX profiles bypass saved preferences for reproducible comparisons. The capture tool compares explicit profiles independently of saved preference. Temporal reconstruction has not been enabled: it needs separate motion and ghosting validation for the custom raymarched surfaces and material sprites.

Coordinator integration smoke confirmed the actual editor viewport uses scale 1.0, bilinear mode 0 and FXAA 1, with the Picture choice visible in the expanded 1280×800 sidebar. [Final control capture](display-integrated/editor-final/construction-and-picture.png), [viewport log](display-integrated/capture-final.log). The ordinary active-input workflow passed 24 checks and the new toolbar-boundary regression passed 13 checks on this configuration; [raw manifests/logs](display-integrated/). This smoke did not automate native popup selection or separately exercise saving a preference across application restarts.
