class_name VoxelCodec
extends RefCounted
## Voxel bit layout (32-bit uint), shared by GDScript and the shaders:
##   bits 0-7   element id
##   bits 8-15  per-voxel random seed (colour variation, rule randomness)
##   bits 16-31 reserved (temperature / life, later phases)

const GRID := 128
const ID_MASK := 0xFF
const SEED_SHIFT := 8


static func encode(id: int, seed: int = 0) -> int:
	return (id & ID_MASK) | ((seed & 0xFF) << SEED_SHIFT)


static func element_id(value: int) -> int:
	return value & ID_MASK


static func seed_of(value: int) -> int:
	return (value >> SEED_SHIFT) & 0xFF


## Linear index into the texture data (x fastest, then y, then z).
static func index(x: int, y: int, z: int) -> int:
	return x + GRID * (y + GRID * z)


static func in_bounds(p: Vector3i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.z >= 0 and p.x < GRID and p.y < GRID and p.z < GRID
