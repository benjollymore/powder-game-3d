extends "res://scripts/sim/voxel_sim.gd"
## Isolated experiment: omit only the intermediate derived rebuild of an
## edit-before-tick transaction. Production scenes never load this subclass.
## Physics order and tick batching remain identical between variants.
var _defer_derived := false
var derived_rebuilds := 0

func _rt_occupancy_update() -> void:
	if _defer_derived:
		return
	derived_rebuilds += 1
	super._rt_occupancy_update()

func _rt_experiment_step(first_tick: int, count: int, stamp: int, coalesce: bool) -> void:
	if stamp >= 0:
		_defer_derived = coalesce and count > 0
		var center := Vector3i(GRID / 2 + (stamp % 25) - 12, GRID * 3 / 4, GRID / 2)
		_rt_paint(center, 4, Elements.Id.SAND, BrushMode.REPLACE, 12345 + stamp)
		_defer_derived = false
	if count > 0:
		_rt_tick(first_tick, count)

func _rt_experiment_reset(ops: Array) -> void:
	# Reset visual history too, so successive cases start from the same state.
	_frame = 0
	_rd.texture_clear(_density_rid, Color(0, 0, 0, 0), 0, FIELDS_MIPS, 0, 1)
	if _fx_pool.is_valid():
		_rd.buffer_clear(_fx_pool, 0, _layer_capacity[Layer.FX] * 48)
		_rd.buffer_clear(_layer_buffer[Layer.FX], 0, _layer_capacity[Layer.FX] * 64)
	_rt_run_ops(ops)
	derived_rebuilds = 0
