class_name VoxelCodec
extends RefCounted
## Voxel bit layout (32-bit uint), shared by GDScript and the shaders:
##   bits 0-7   element id
##   bits 8-15  per-voxel random seed (colour variation, rule randomness)
##   bits 16-23 liquid amount (0 for anything that is not a liquid)
##   bits 24-31 movement flags (liquid falling-run marker and powder moved age)

## World size per axis. Resolved once from the project setting
## `powder/sim/grid_size`, overridden by a `grid=N` command-line user arg
## (after `--`) so tests can run small while play runs large. Must be a
## multiple of 8.
static var GRID: int = _resolve_grid()


static func _resolve_grid() -> int:
	var g: int = int(ProjectSettings.get_setting("powder/sim/grid_size", 128))
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("grid="):
			g = int(arg.substr(5))
	assert(g >= 16 and g % 8 == 0, "grid_size must be a multiple of 8")
	return g
const ID_MASK := 0xFF
const SEED_SHIFT := 8
const AMOUNT_SHIFT := 16


static func encode(id: int, seed: int = 0, amount: int = 0) -> int:
	return (id & ID_MASK) | ((seed & 0xFF) << SEED_SHIFT) | ((amount & 0xFF) << AMOUNT_SHIFT)


static func amount_of(value: int) -> int:
	return (value >> AMOUNT_SHIFT) & 0xFF


static func element_id(value: int) -> int:
	return value & ID_MASK


static func seed_of(value: int) -> int:
	return (value >> SEED_SHIFT) & 0xFF


## Linear index into the texture data (x fastest, then y, then z).
static func index(x: int, y: int, z: int) -> int:
	return x + GRID * (y + GRID * z)


static func in_bounds(p: Vector3i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.z >= 0 and p.x < GRID and p.y < GRID and p.z < GRID
