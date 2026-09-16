extends RefCounted
## Shared WASD fly motion, extracted from scripts/camera/free_camera.gd so the
## legacy scenario viewer and the paint editor use one implementation.
##
## The caller owns the camera and its orientation; this object owns only the
## velocity, the sprint field-of-view boost and the fly speed. Speeds are
## authored for a 1 m box and scaled by the world size, so the feel is the same
## at any grid resolution. Movement is independent of TimeController: you can
## fly while the experiment is frozen.
##
## Forward and right follow the view; up and down stay world-aligned, so flying
## feels like a drone rather than a spaceship.

const KEYS := [KEY_W, KEY_A, KEY_S, KEY_D, KEY_Q, KEY_E]

var fly_speed := 2.0
var sprint_multiplier := 4.0
## Seconds to reach most of the target speed, and to coast to a stop.
var accel_time := 0.12
var brake_time := 0.18
## Extra field of view while sprinting, eased in and out.
var sprint_fov_boost := 8.0
var world_size := 1.0
var velocity := Vector3.ZERO
var fov_boost := 0.0


func _init(size: float = 1.0) -> void:
	world_size = maxf(size, 0.000001)
	fly_speed *= world_size


## Movement request from the currently held keys, in camera-local terms:
## x right, y up (world), z back. Callers that must ignore the keyboard (a
## focused text field, a modal) pass `false` and get a stop.
static func input_vector(active: bool) -> Vector3:
	if not active:
		return Vector3.ZERO
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input.x += 1.0
	if Input.is_key_pressed(KEY_E):
		input.y += 1.0
	if Input.is_key_pressed(KEY_Q):
		input.y -= 1.0
	return input


## Advance one frame. `basis` is the camera's orientation, `input` the request
## from `input_vector`, `sprinting` whether Shift is held. Returns the position
## delta to apply; `fov_boost` holds the eased sprint boost afterwards.
func step(delta: float, basis: Basis, input: Vector3, sprinting: bool) -> Vector3:
	var moving := input != Vector3.ZERO
	var sprint := moving and sprinting
	var speed := fly_speed * (sprint_multiplier if sprint else 1.0)
	var move := basis.x * input.x + basis.z * input.z
	move.y = 0.0
	move = move.normalized() * Vector2(input.x, input.z).length() + Vector3.UP * input.y
	var wanted := move.normalized() * speed if moving else Vector3.ZERO
	# Ease toward the wanted velocity so starts and stops feel like mass.
	var tau := accel_time if wanted.length() > velocity.length() else brake_time
	velocity = velocity.lerp(wanted, 1.0 - exp(-delta / maxf(tau, 0.001)))
	if velocity.length() < 0.001 * world_size:
		velocity = Vector3.ZERO
	fov_boost = lerpf(fov_boost, sprint_fov_boost if sprint else 0.0, 1.0 - exp(-6.0 * delta))
	return velocity * delta


## A held key released elsewhere (focus loss, Test entry, a modal) must not
## leave the camera coasting on a stale request.
func stop() -> void:
	velocity = Vector3.ZERO


## Scroll-wheel speed adjustment, clamped to the world size as in the legacy rig.
func scroll(direction: float) -> void:
	fly_speed = clampf(fly_speed * (1.25 if direction > 0.0 else 0.8), 0.1 * world_size, 50.0 * world_size)
