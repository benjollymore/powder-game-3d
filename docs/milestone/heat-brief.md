# Milestone: Heat and reactions sandbox

Start: 2026-09-15. Base: `main` at `a18caec`. Integration branch `milestone/heat` in `powder-game-3d-discovery/heat`. The full roadmap and acceptance list is [heat-roadmap.md](heat-roadmap.md); this brief pins the contracts workers depend on so all four can start at once. The fundamentals [brief](brief.md) rules still apply: integer cell coordinates, GPU state authoritative, edits as ordered commands, presentation never defines physics time, one visible GPU process at a time assigned by the coordinator, no timing claims unless mains power and idle GPU.

## Outcome

A sandbox toy: pick anything from a categorised palette, paint it into a running world, and get a legible hot/cold-driven reaction within seconds. Ten new elements, a real temperature layer, heat/cool brushes, a hover inspector, time scale, an Examples picker, and seven chain-reaction scenarios. No goals, no levels.

## Ownership

| Worker | Worktree / branch | Owns |
|---|---|---|
| thermal | `heat-thermal` / `milestone/heat-thermal` | thermal texture and bindings in `voxel_sim.gd`; `sim.glsl` thermal/phase rules and transfer contract; `hydro.glsl` remap; `air_downsample.glsl` buoyancy; `brush.glsl` HEAT/COOL; `region_copy.glsl` and `surface_pick.glsl` thermal payloads; tranche A elements' thermal values; energy/cadence tests |
| elements | `heat-elements` / `milestone/heat-elements` | `elements.gd` v2 schema and `elem.glslinc` (lands first); tranche B elements and their `sim.glsl` rules; `scenarios.gd`; CPU oracle; `run_gpu_tests.gd` additions |
| editor | `heat-editor` / `milestone/heat-editor` | palette panel, categories, tooltips, HEAT/COOL brush UI, inspector display, time slider, Examples, Keep result, `world_archive.gd` v2, guard integration, editor tests |
| rendering | `heat-rendering` / `milestone/heat-rendering` | palette 16 -> 32 across spatial shaders (lands first); temperature glow; ICE/GLASS material layers; matched captures |
| coordinator | `heat` / `milestone/heat` | contracts, cherry-pick integration, independent reruns, GPU lease, status, reviews |

`sim.glsl` is shared by method: elements owns the `struct Elem` include and new pair/bespoke rules; thermal owns `rule_thermal`, `rule_phase`, transfer mixing and `swap_cells`. `elements.gd` is shared by key: elements owns the schema and non-thermal values; thermal owns the thermal coefficient values. Communicate before crossing.

## Contracts (pinned)

1. **`Elements.TABLE` v2 keys.** Existing keys unchanged. New keys, all with defaults so old rows keep working: `category` (one of `common`, `heat`, `powders`, `liquids`, `gases`, `solids`, `special`), `tip` (one sentence), `heat_capacity` (J/K per full cell, > 0), `conductivity` (W/(m K)), `initial_temp` (K), `fire_temp` (K, gases that are fire), `ignition_temp` (K, flammables; 0 = never), `hot_at` / `hot_to` (K, id), `cold_at` / `cold_to` (K, id), `latent` (K x capacity units for the plateau), `burn_to` (id). Encoded into a 64-byte `Elem` (`ELEM_BYTES = 64`): first 32 bytes exactly as today, second 32 bytes `vec4 thermal_a = (heat_capacity, conductivity, initial_temp, fire_temp)`, `vec4 thermal_b = (ignition_temp, hot_at, cold_at, latent)`, then `uint ids = hot_to | cold_to << 8 | burn_to << 16` in the first component of a trailing uvec4 (the rest zero). One `shaders/compute/elem.glslinc` replaces every copy of `struct Elem`; a unit check compares `Elements.ELEM_BYTES` with a `ELEM_BYTES_SENTINEL` constant in the include. Element ids: existing 0..9 unchanged; tranche A `ICE=10, LAVA=11, STONE=12, METAL=13`; tranche B `WAX=14, MOLTEN_WAX=15, GUNPOWDER=16, GAS=17, ACID=18, CLONE=19, VOID=20`, `GLASS=21` reserved. `PALETTE_SIZE = 32`.
2. **Reactions.** `REACTIONS` rows stay `[a, b, out_a, out_b, p]` with an optional sixth element `{ "min_t": K, "heat": K-per-full-cell }`; encoded into the two spare uints of `reaction_bytes()` as float bits. One rule per unordered pair, first match wins; order is documented in the table comment.
3. **Thermal texture.** `R32G32_SFLOAT`, grid extent, R = temperature in kelvin, G = latent progress. `VoxelSim.thermal_texture_rid()` and `VoxelSim.thermal_texture` (a `Texture3DRD`, format `Image.FORMAT_RGF`) for renderer and pick. Ambient `VoxelSim.ambient_temp` default 293.15 K. Thermal is authoritative cell state: upload, reset, readback, regional history, Return, Keep, archive and scenario load all include it, via one `VoxelSim.authoritative_textures()` list. `upload(bytes, thermal := PackedByteArray())` initialises thermal from `initial_temp` when empty. `request_thermal_readback()` -> `thermal_ready(bytes)`. Static `VoxelSim.energy_total(voxels, thermal) -> float` for tests. Day-1 verification by thermal: `Texture3DRD` accepts `FORMAT_RGF`; if not, fall back to `R32_SFLOAT` (`FORMAT_RF`) plus latent progress in `grid.A` bits 3..7 and tell the coordinator.
4. **Probe.** `VoxelSim.request_cell_probe(origin: Vector3, dir: Vector3, callback)` -> `{ "pos": Vector3i, "element": int, "temperature": float, "amount": int, "flags": int }` or `pos.x == -1` on miss, carried in the spare bytes 52..63 of the existing 64-byte pick record decoded by `EditGPU.decode_pick`. Thermal implements the kernel side; editor consumes it.
5. **Brushes.** `Brush.Mode.HEAT` and `COOL` in `scripts/sim/brush.gd`; `brush.glsl` adds `+-strength` kelvin within the sphere with radius falloff, voxel bytes untouched. Element paint writes `initial_temp[element]`. Thermal owns the kernel, editor the UI.
6. **Archive v2.** `WorldArchive.VERSION = 2`, schema `material-seed-amount-flags-rgba8+temperature-latent-rg32f-v2`, header `layers: [{ name, format, size, sha256 }]`, payload = layers concatenated then zstd; v1 loads with default temperatures. Editor owns the file code; thermal supplies the bytes.
7. **Scenarios.** `WorldBuilder` ops gain an optional `temp` (K) argument defaulting to `initial_temp[id]`; `Scenarios.build(name)` returns `{ "voxels": PackedInt32Array, "thermal": PackedFloat32Array }`. CPU replay remains the test oracle.

## Order of landing

1. elements: `TABLE` v2 keys with defaults + `elem.glslinc` + 64-byte `Elem` + sentinel check (no behaviour change; all suites byte-identical). rendering: palette 32 (byte-identical captures). Both land within the first session so the others rebase onto them.
2. thermal: texture, bindings, upload/reset/readback, authoritative list; then rules and contract; then brushes, region copy, pick.
3. editor: palette UI, time slider, Examples, Keep (can start on the v2 keys immediately); inspector and archive v2 once thermal exposes bytes.
4. elements: tranche B rules and scenarios, one physics test each.
5. rendering: temperature glow and ICE/GLASS layers once the thermal texture is bound.

## Rules

- Commit small coherent units on your branch; never rebase or merge another worker's branch; the coordinator cherry-picks and tells you when to `git reset --hard milestone/heat`.
- CPU suites and `--headless --check-only` run freely. Visible GPU runs only while you hold the lease, granted by the coordinator in a message; run `godot --headless --path . --import` before the first visible run after any kernel change; end your turn to release the lease.
- Do not commit `.glsl.import` churn on tracked kernels; do commit new `.uid` and new-kernel `.import` files.
- Report evidence and remaining risks, not implementation claims. Numbers only from mains power and an idle GPU, and say so.
- Ben's Godot may be open in another worktree; never kill it.
