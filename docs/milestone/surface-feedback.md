# Surface targeting and cutaway recovery

The default container opens in a cutaway with its positive Z side hidden. Switching to Material surface previously gave no visible placement preview when pointing at the water's cut face: the GPU correctly found the exposed face, offset the additive brush outward, then rejected a target beyond the visible section. The section checkbox was inside collapsed construction tools, so the correct rejection appeared to be a broken paint tool.

Cutaway is now an explicit toggle beside Paint on. Selecting Surface preserves the chosen view. When an authoritative preview reports a target blocked by that cutaway, an adjacent **Cutaway blocks paint here · Show whole world** action explains and resolves it. Clicking it finishes/cancels the current stroke through the existing gesture boundary, disables the visual section, invalidates stale previews and queries the newly visible geometry. It keeps the same camera, brush, exact plane coordinates, targeting mode and Build/Test phase. The toggle and recovery change no voxel bytes.

Surface feedback distinguishes a section rejection, a world-boundary rejection, starting inside material, an empty-space miss and an outstanding preview. It does not invent a fallback target. Erase remains valid on the actual cut face. The GPU picking and brush kernels are unchanged.

The first 1280×800 capture showed the extra recovery row pushing the status footer below the panel. The main help now retains two essential paint/trackpad navigation lines; secondary shortcuts remain in the existing expanded Construction & shortcuts tools and in the help tooltip. The footer avoids repeating the cutaway explanation already present on its action. The final blocked Build and paused Test layouts keep recovery, controls and the complete status inside the sidebar. See [blocked cut face](surface-feedback-evidence/blocked-cut-face.png) and [paused Test](surface-feedback-evidence/paused-test-cutaway.png).

The actual default-scene hover at 128³ reported hit `(64,26,64)`, normal `+Z`, target `(64,26,68)`, invalid because the section ends at cell 64. After the explicit recovery, the same screen position reported visible container wall hit `(64,34,95)` and valid target `(64,34,99)`. At 256³ the corresponding results were blocked hit `(128,52,128)` → target `(128,52,132)`, then valid whole-world hit `(128,67,191)` → target `(128,67,195)`. The changed hit is the actual newly visible geometry under the same camera ray.

Validation on Godot 4.6.3 / Metal / Apple M5 Pro:

- [GPU 128³](surface-feedback-evidence/gpu128.log): 20/20 checks.
- [GPU 256³](surface-feedback-evidence/gpu256.log): 20/20 checks.
- [Headless feedback/source guards](surface-feedback-evidence/cpu.log): 10/10 checks.
- [Existing active-frame editor workflow](surface-feedback-evidence/workflow.log): 24/24 checks; keyboard routing 8/8, native gesture routing 10/10, and paint-tool guards 9/9 also passed.

The GPU harness keeps both production frame loops active. It uses synchronized OS cursor position plus parsed engine input for real hover, opening the targeting dropdown, clicking recovery, painting, erasing, Undo, Run, Pause, step and Return. Exact packed-byte comparisons verify that showing the whole world changes no material, recovered additive paint preserves every wall, and both paint and erase undo exactly. A paused live Sand source is explicitly valid before a view change; changing Cutaway cancels it, and the next authoritative tick adds no stale Sand. A programmatic toggle of the real checkbox models that view command while the primary button is held; the earlier recovery uses actual parsed GUI clicks.

There is one explicit harness limitation: parsed root keys and `PopupMenu.push_input` keys did not select the item in Godot's embedded dropdown on this Mac. The test verifies the real popup opens, then closes it and invokes the OptionButton's semantic selection signal. It does not claim automated native popup keyboard selection or physical trackpad testing. A new press also deliberately invalidates its hover cache; the source-boundary assertion records the valid pre-press preview instead of expecting the old cache to remain present after the gesture begins.

```sh
godot --headless --path . -s res://tests/milestone/surface_feedback.gd
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/surface_feedback_gpu.gd -- grid=128
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/milestone/surface_feedback_gpu.gd -- grid=256
```

Fresh captures default to `/tmp/editor-surface-feedback/grid128` or `grid256`; `output_dir=` selects a separate evidence directory. Raw final logs are also preserved with this report. This unit changes presentation and feedback around existing geometric rules; it does not alter region selection, surface masks, material simulation, history format or the default exact workplane.

Coordinator integration checks also pass: 20 GPU checks at each grid size, 10 feedback CPU checks and eight keyboard checks. Raw logs, distinct captures and command manifests are preserved in [cutaway-integrated](cutaway-integrated/). The integration harness honors output-directory overrides so reruns preserve earlier evidence.
