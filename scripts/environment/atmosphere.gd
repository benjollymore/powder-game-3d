extends Node3D
## Owns the look: sky, sun, ground, glass frame, tilt-shift depth of field and
## the time-scale post effect. Keeps the voxel raymarcher's lighting uniforms
## in sync with the scene's sun and sky so voxels and meshes agree.

const BOX_CENTER := Vector3.ZERO

@export var sim_mesh_path: NodePath = ^"../SimVolume/Mesh"
@export var camera_path: NodePath = ^"../CameraRig/Camera3D"
@export var dof_enabled := true:
	set(v):
		dof_enabled = v
		_apply_dof_enabled()
## How far in front of and behind the box centre stays sharp (world units).
## Depth-of-field band around the box, in box widths.
@export var dof_sharp_band := 1.0
@export var dof_transition := 0.9
@export var dof_blur_amount := 0.07
## Direction the sunlight travels (world space). Chosen so the box's shadow
## falls toward the default camera side.
@export var sun_direction := Vector3(-0.55, -0.8, 0.45)
@export var frame_color := Color(0.18, 0.2, 0.24, 0.55)
@export var frame_thickness := 0.004

@onready var sun: DirectionalLight3D = $Sun
@onready var world_env: WorldEnvironment = $WorldEnvironment
@onready var fx_rect: ColorRect = $PostFX/TimeScaleFX

var _sim: Node3D
var _ground_material: ShaderMaterial
var _camera: Camera3D
var _attributes: CameraAttributesPractical


## Box edge length in metres; the environment is tuned relative to it.
var world_size := 1.0


func _ready() -> void:
	add_to_group("atmosphere")
	var sim := get_tree().get_first_node_in_group("sim")
	if sim and sim.has_method("world_size"):
		world_size = sim.world_size()
	_apply_world_scale()
	_sim = get_tree().get_first_node_in_group("sim")
	_ground_material = $Ground.get_surface_override_material(0) as ShaderMaterial
	if _ground_material and _sim:
		_ground_material.set_shader_parameter("sunvis", _sim.sunvis_texture())
		_ground_material.set_shader_parameter("box_center", Vector3.ZERO)
		_ground_material.set_shader_parameter("box_half", 0.5 * world_size)
	_camera = get_node_or_null(camera_path) as Camera3D
	if _camera:
		_attributes = CameraAttributesPractical.new()
		_attributes.dof_blur_amount = dof_blur_amount
		_camera.attributes = _attributes
		_apply_dof_enabled()
	sun.look_at(sun.global_position + sun_direction.normalized(), Vector3.UP)
	_build_box_frame()
	_sync_lighting()


## Everything authored for a 1 m box scales with the actual box.
func _apply_world_scale() -> void:
	var w := world_size
	$Ground.position.y = -0.5 * w
	$BoundsOutline.position.y = -0.498 * w
	$BoundsOutline.scale = Vector3.ONE * w
	var env: Environment = world_env.environment
	env.fog_density = 0.02 / w
	env.fog_height = -0.5 * w
	env.ssao_radius = 0.6 * w
	sun.directional_shadow_max_distance = 30.0 * w


func _process(_delta: float) -> void:
	_sync_lighting()
	_update_dof()
	_update_fx()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		dof_enabled = not dof_enabled
		get_viewport().set_input_as_handled()


## Push sun direction/colour and sky/ground tints into the raymarch materials
## and the ground shadow shader.
func _sync_lighting() -> void:
	if _sim == null:
		return
	# A DirectionalLight3D shines along its -Z, so +Z points back toward the sun.
	var to_sun: Vector3 = sun.global_transform.basis.z.normalized()
	_sim.sun_to = to_sun
	_sim.set_param("light_dir", to_sun)
	_sim.set_param("sun_color", sun.light_color * sun.light_energy)
	var sky_mat := world_env.environment.sky.sky_material as ProceduralSkyMaterial
	if sky_mat:
		_sim.set_param("sky_color", sky_mat.sky_horizon_color.lerp(sky_mat.sky_top_color, 0.5))
		_sim.set_param("ground_color", sky_mat.ground_bottom_color)
	if _ground_material:
		_ground_material.set_shader_parameter("to_sun", to_sun)


func _apply_dof_enabled() -> void:
	if _attributes == null:
		return
	_attributes.dof_blur_far_enabled = dof_enabled
	_attributes.dof_blur_near_enabled = dof_enabled


## Tilt-shift: keep the box sharp, blur everything nearer or farther.
func _update_dof() -> void:
	if _attributes == null or not dof_enabled:
		return
	var focus := _camera.global_position.distance_to(BOX_CENTER)
	var band := dof_sharp_band * world_size
	var trans := dof_transition * world_size
	_attributes.dof_blur_far_distance = focus + band
	_attributes.dof_blur_far_transition = trans
	_attributes.dof_blur_near_distance = maxf(focus - band, 0.02)
	_attributes.dof_blur_near_transition = trans


func _update_fx() -> void:
	var mat := fx_rect.material as ShaderMaterial
	if mat == null:
		return
	var s: float = TimeController.effective_scale
	var slow := 1.0 - clampf(s, 0.0, 1.0)
	if TimeController.paused:
		slow = 1.0
	var fast := clampf((s - 1.0) / 3.0, 0.0, 1.0)
	mat.set_shader_parameter("slow_amount", slow)
	mat.set_shader_parameter("fast_amount", fast)


## Twelve thin bars along the edges of the unit box.
func _build_box_frame() -> void:
	var bar := BoxMesh.new()
	bar.size = Vector3(1.0, frame_thickness, frame_thickness)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = frame_color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.6
	var half := 0.5
	var edges: Array = []
	for a in [-half, half]:
		for b in [-half, half]:
			edges.append([Vector3(0, a, b), Vector3.ZERO])                                      # along X
			edges.append([Vector3(a, 0, b), Vector3(0, 0, deg_to_rad(90))])                     # along Y
			edges.append([Vector3(a, b, 0), Vector3(0, deg_to_rad(90), 0)])                     # along Z
	var root := Node3D.new()
	root.name = "BoxFrame"
	root.scale = Vector3.ONE * world_size
	add_child(root)
	for e in edges:
		var mi := MeshInstance3D.new()
		mi.mesh = bar
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = e[0]
		mi.rotation = e[1]
		root.add_child(mi)
