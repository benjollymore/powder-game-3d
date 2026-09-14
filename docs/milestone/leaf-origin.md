# Finite leaf origins for symmetric exposure

An isolated plant cell, or one exposed equally in opposing directions, could emit a leaf with a NaN position. The kernel summed its exposed-face normals and normalized that sum to offset the leaf origin. Opposing directions cancel to zero. Existing sprite tests counted emitted leaves but did not inspect their transform floats, so they passed even when these records had invalid positions.

On the original `1d2f675` implementation, the GPU probe covered all 64 face-exposure masks. Of the 63 exposed masks, **seven emitted `(NaN, NaN, NaN)` origins** on Godot 4.6.3 / Metal 4.0 / Apple M5 Pro. The fully buried mask emitted no leaf, as intended. [Original probe log](evidence-simulation/leaf-baseline128.log).

The fix preserves normalization for nonzero sums. For a zero sum, it uses the existing deterministic cell hash to choose one of the exposed faces, then offsets the origin 0.45 cells through that face. This affects origin placement only; leaf orientation, scale, custom data, emission counts, and physics rules are unchanged. The face mask is gathered during the existing neighbor scan, with no extra grid reads.

The regression uses a live legacy-expression control compiled on the same GPU, avoiding brittle cross-device comparisons against frozen floating-point bytes. It covers all exposure masks and checks every transform/custom-data float for finiteness, the intended offset length, exposed-face selection, deterministic refresh, and exact physical state preservation.

- **203 checks pass at 128³ and at 256³.** All 56 nonzero-direction leaf records are byte-identical to the legacy control. The seven corrected records retain exact orientation/scale/custom bytes. Counts, voxel bytes, and all seven air textures remain equal. [128³ log](evidence-simulation/leaf-fixed128.log), [256³ log](evidence-simulation/leaf-fixed256.log).
- **74 existing GPU128 invariant checks pass**, without changed assertions or numerical thresholds. [Regression log](evidence-simulation/gpu128-leaf-fixed.log).
- Fresh shader import and script parsing pass. No GPU resource leak diagnostics occurred in these runs.

Reproduce serially with a visible window:

```sh
godot --headless --path . --import
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/milestone/leaf_finite.gd -- grid=128
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/milestone/leaf_finite.gd -- grid=256
godot --path . --always-on-top --disable-vsync --resolution 320x240 -s res://tests/gpu/run_gpu_tests.gd -- grid=128
```

For a diagnostic of the original expression on the current branch, append `legacy_probe=1` to the leaf harness. Diagnostic mode prints nonfinite positions without treating them as test failures; ordinary regression mode requires finite positions. The historical baseline log was captured before applying the fix, using `probe=1` on `1d2f675`.
