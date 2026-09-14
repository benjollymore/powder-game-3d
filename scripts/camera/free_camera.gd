extends Node3D
## Free-flying camera rig: free flight by default, orbit mode on demand.
##
## The rig node carries position and yaw/pitch; the Camera3D child sits at the
## rig origin in fly mode and is pushed back along +Z in orbit mode. Camera
## movement is independent of TimeController, so you can fly while frozen.

enum Mode { FLY, ORBIT }

@export var fly_speed := 2.0
@export var sprint_multiplier := 4.0
@export var look_sensitivity := 0.0025
@export var orbit_target := Vector3.ZERO
@export var orbit_distance := 3.0
@export var frame_position := Vector3(1.7, 1.3, 1.7)

var mode := Mode.FLY
var _yaw := 0.0
var _pitch := 0.0
var _tween: Tween

@onready var camera: Camera3D = $Camera3D


func _ready() -> void:
	frame_box(false)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_VISIBLE
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_scroll(1.0)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_scroll(-1.0)
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * look_sensitivity
		_pitch = clampf(_pitch - event.relative.y * look_sensitivity, -PI / 2.0 + 0.01, PI / 2.0 - 0.01)
		_apply_rotation()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F:
				frame_box(true)
			KEY_O:
				set_mode(Mode.ORBIT if mode == Mode.FLY else Mode.FLY)
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	if mode != Mode.FLY or (_tween and _tween.is_running()):
		return
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
	if input == Vector3.ZERO:
		return
	var speed := fly_speed * (sprint_multiplier if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	# Forward/right follow the view; up/down stay world-aligned so flying feels like a drone.
	var basis := global_transform.basis
	var move := (basis.x * input.x + basis.z * input.z)
	move.y = 0.0
	move = move.normalized() * Vector2(input.x, input.z).length() + Vector3.UP * input.y
	global_position += move.normalized() * speed * delta


func set_mode(new_mode: Mode) -> void:
	if mode == new_mode:
		return
	if new_mode == Mode.ORBIT:
		orbit_distance = maxf(global_position.distance_to(orbit_target), 0.5)
		global_position = orbit_target
		camera.position = Vector3(0.0, 0.0, orbit_distance)
		look_at_target()
	else:
		global_position = camera.global_position
		camera.position = Vector3.ZERO
	mode = new_mode


## Point the rig at the orbit target from its current position.
func look_at_target() -> void:
	var to_target := orbit_target - global_position
	if mode == Mode.ORBIT:
		# In orbit mode the rig sits on the target; keep the current yaw/pitch.
		_apply_rotation()
		return
	if to_target.length_squared() < 0.0001:
		return
	_yaw = atan2(-to_target.x, -to_target.z)
	_pitch = asin(clampf(to_target.normalized().y, -1.0, 1.0))
	_apply_rotation()


## Move the camera to a good vantage point looking at the box.
func frame_box(animate: bool) -> void:
	if mode == Mode.ORBIT:
		set_mode(Mode.FLY)
	var target_dir := orbit_target - frame_position
	var target_yaw := atan2(-target_dir.x, -target_dir.z)
	var target_pitch := asin(clampf(target_dir.normalized().y, -1.0, 1.0))
	if not animate:
		global_position = frame_position
		_yaw = target_yaw
		_pitch = target_pitch
		_apply_rotation()
		return
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_tween.tween_property(self, "global_position", frame_position, 0.5)
	_tween.tween_method(_set_yaw_pitch, Vector2(_yaw, _pitch), Vector2(target_yaw, target_pitch), 0.5)


func _set_yaw_pitch(v: Vector2) -> void:
	_yaw = v.x
	_pitch = v.y
	_apply_rotation()


func _apply_rotation() -> void:
	rotation = Vector3(_pitch, _yaw, 0.0)


func _scroll(direction: float) -> void:
	if mode == Mode.ORBIT:
		orbit_distance = clampf(orbit_distance * (0.9 if direction > 0.0 else 1.1), 0.3, 20.0)
		camera.position = Vector3(0.0, 0.0, orbit_distance)
	else:
		fly_speed = clampf(fly_speed * (1.25 if direction > 0.0 else 0.8), 0.1, 50.0)
