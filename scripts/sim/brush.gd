extends Node3D
## Spherical paint brush. Casts the mouse ray into the box, places the cursor
## `cursor_depth` along the ray past the box entry point, shows a translucent
## sphere gizmo there, and paints while the left button is held. Works while
## time is frozen; the paint lands the same frame.
##
## Keys: 1-7 pick an element, X toggles erase, [ ] change radius,
## Shift+scroll moves the cursor along the ray.

signal changed

const GRID := VoxelCodec.GRID
const MIN_RADIUS := 1
const MAX_RADIUS := 12

@export var sim_path: NodePath
@export var camera_path: NodePath

var element: int = Elements.Id.SAND:
	set(v):
		element = v
		changed.emit()
var radius := 4:
	set(v):
		radius = clampi(v, MIN_RADIUS, MAX_RADIUS)
		changed.emit()
var erase := false:
	set(v):
		erase = v
		changed.emit()
var cursor_depth := 0.45
var cursor_voxel := Vector3i.ZERO
var cursor_valid := false

var _painting := false
@onready var _sim: Node3D = get_node(sim_path)
@onready var _camera: Camera3D = get_node(camera_path)
@onready var _gizmo: MeshInstance3D = $Gizmo


func _ready() -> void:
	add_to_group("brush")
	changed.connect(_on_changed)
	_update_gizmo_size()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_painting = event.pressed
			get_viewport().set_input_as_handled()
		elif event.pressed and event.shift_pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var dir := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
			cursor_depth = clampf(cursor_depth + dir * 0.03, 0.0, 2.0)
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7:
				var id: int = event.keycode - KEY_1 + 1
				if id < Elements.count():
					element = id
					erase = false
			KEY_X:
				erase = not erase
			KEY_BRACKETLEFT:
				radius -= 1
			KEY_BRACKETRIGHT:
				radius += 1
			_:
				return
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_update_cursor()
	_gizmo.visible = cursor_valid
	if cursor_valid:
		_gizmo.global_position = (Vector3(cursor_voxel) + Vector3(0.5, 0.5, 0.5)) / GRID - Vector3(0.5, 0.5, 0.5)
	if _painting and cursor_valid:
		var mode: int = _sim.BrushMode.ERASE if erase else _sim.BrushMode.REPLACE
		_sim.paint(cursor_voxel, radius, element, mode)


func _update_cursor() -> void:
	var mouse := get_viewport().get_mouse_position()
	var origin := _camera.project_ray_origin(mouse)
	var dir := _camera.project_ray_normal(mouse)
	var hit := ray_box(origin, dir)
	cursor_valid = hit.x >= 0.0
	if not cursor_valid:
		return
	var t := hit.x + clampf(cursor_depth, 0.0, hit.y - hit.x)
	var p := (origin + dir * t + Vector3(0.5, 0.5, 0.5)) * GRID
	cursor_voxel = Vector3i(p.floor()).clamp(Vector3i.ZERO, Vector3i(GRID - 1, GRID - 1, GRID - 1))


## Intersect a ray with the unit box centred at the origin (world == model
## space for the sim volume). Returns (t_enter, t_exit) or (-1, -1) on a miss.
static func ray_box(origin: Vector3, dir: Vector3) -> Vector2:
	var t0 := -INF
	var t1 := INF
	for axis in 3:
		var d: float = dir[axis]
		var o: float = origin[axis]
		if absf(d) < 1e-8:
			if o < -0.5 or o > 0.5:
				return Vector2(-1.0, -1.0)
			continue
		var a := (-0.5 - o) / d
		var b := (0.5 - o) / d
		t0 = maxf(t0, minf(a, b))
		t1 = minf(t1, maxf(a, b))
	t0 = maxf(t0, 0.0)
	if t1 < t0:
		return Vector2(-1.0, -1.0)
	return Vector2(t0, t1)


func _update_gizmo_size() -> void:
	var d := float(2 * radius + 1) / GRID
	_gizmo.scale = Vector3(d, d, d)


func _on_changed() -> void:
	_update_gizmo_size()
