extends Node
## Owns simulation time. Autoloaded as `TimeController`.
##
## The simulation never advances on its own. Every frame this node decides how
## many whole ticks should run (usually 0 or 1, at most MAX_TICKS_PER_FRAME) and
## emits `ticks_requested`. Rendering, camera and painting keep running every
## frame regardless, so a frozen world is fully explorable and editable.

signal ticks_requested(count: int)
signal paused_changed(paused: bool)
signal time_scale_changed(target_scale: float)

## Simulation ticks per second at real time. A grain pairs with the cell below
## on about half the ticks, so 180 gives ~90 voxels/s of free fall.
const TICKS_PER_SECOND := 180.0
const MAX_TICKS_PER_FRAME := 8
const MIN_SCALE := 1.0 / 32.0
const MAX_SCALE := 4.0
## Seconds it takes to ramp between time scales, so slow-mo eases in.
const SMOOTHING := 0.15

var paused := false:
	set(value):
		if paused == value:
			return
		paused = value
		_accumulator = 0.0
		paused_changed.emit(paused)

## Target time scale. 0..MIN_SCALE is treated as frozen; 1.0 is real time.
var time_scale := 1.0:
	set(value):
		value = clampf(value, 0.0, MAX_SCALE)
		if is_equal_approx(time_scale, value):
			return
		time_scale = value
		time_scale_changed.emit(time_scale)

## The smoothed scale actually applied this frame.
var effective_scale := 1.0
## Total ticks run since the world was last cleared.
var tick := 0
## Ticks run during the most recent frame.
var ticks_this_frame := 0
## Measured ticks per second, refreshed twice a second.
var ticks_per_second := 0.0

var _accumulator := 0.0
var _pending_steps := 0
var _tps_window_ticks := 0
var _tps_window_time := 0.0


func _process(delta: float) -> void:
	# Exponential ease toward the target scale.
	var blend := 1.0 - exp(-delta / SMOOTHING)
	effective_scale = lerpf(effective_scale, time_scale, blend)
	if absf(effective_scale - time_scale) < 0.001:
		effective_scale = time_scale

	var result := compute_ticks(delta, paused, effective_scale, _pending_steps, _accumulator)
	ticks_this_frame = result[0]
	_accumulator = result[1]
	_pending_steps = 0

	tick += ticks_this_frame
	_tps_window_ticks += ticks_this_frame
	_tps_window_time += delta
	if _tps_window_time >= 0.5:
		ticks_per_second = _tps_window_ticks / _tps_window_time
		_tps_window_ticks = 0
		_tps_window_time = 0.0

	ticks_requested.emit(ticks_this_frame)


## Pure tick scheduling, kept static so it can be unit-tested headless.
## Returns [ticks_to_run, new_accumulator].
static func compute_ticks(delta: float, is_paused: bool, scale: float,
		pending_steps: int, accumulator: float) -> Array:
	var count := pending_steps
	if not is_paused and scale >= MIN_SCALE:
		accumulator += scale * TICKS_PER_SECOND * delta
		var whole := int(accumulator)
		accumulator -= whole
		count += whole
	if count > MAX_TICKS_PER_FRAME:
		# Drop the excess rather than spiralling behind on slow frames.
		count = MAX_TICKS_PER_FRAME
		accumulator = 0.0
	return [count, accumulator]


func toggle_pause() -> void:
	paused = not paused


## Queue exactly one tick for the next frame (works whether or not paused;
## the common use is stepping a frozen world).
func step() -> void:
	paused = true
	_pending_steps += 1


func is_frozen() -> bool:
	return paused or time_scale < MIN_SCALE


func reset_tick_counter() -> void:
	tick = 0
	_accumulator = 0.0
	_pending_steps = 0


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			toggle_pause()
		KEY_N:
			step()
		KEY_COMMA:
			time_scale = maxf(time_scale * 0.5, MIN_SCALE)
		KEY_PERIOD:
			time_scale = minf(maxf(time_scale, MIN_SCALE) * 2.0, MAX_SCALE)
		KEY_0:
			time_scale = 0.0
		KEY_1:
			time_scale = 1.0
			paused = false
		_:
			return
	get_viewport().set_input_as_handled()
