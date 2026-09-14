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

var _sim_material: ShaderMaterial
var _camera: Camera3D
var _attributes: CameraAttributesPractical


func _ready() -> void:
	var mesh := get_node_or_null(sim_mesh_path) as MeshInstance3D
	if mesh:
		_sim_material = mesh.material_override as ShaderMaterial
	_camera = get_node_or_null(camera_path) as Camera3D
	if _camera:
		_attributes = CameraAttributesPractical.new()
		_attributes.dof_blur_amount = dof_blur_amount
		_camera.attributes = _attributes
		_apply_dof_enabled()
	sun.look_at(sun.global_position + sun_direction.normalized(), Vector3.UP)
	_build_box_frame()
	_sync_lighting()


func _process(_delta: float) -> void:
	_sync_lighting()
	_update_dof()
	_update_fx()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		dof_enabled = not dof_enabled
		get_viewport().set_input_as_handled()


## Push sun direction/colour and sky/ground tints into the raymarch material.
func _sync_lighting() -> void:
	if _sim_material == null:
		return
	var to_sun := -sun.global_transform.basis.z
	_sim_material.set_shader_parameter("light_dir", to_sun)
	_sim_material.set_shader_parameter("sun_color", sun.light_color * sun.light_energy)
	var sky_mat := world_env.environment.sky.sky_material as ProceduralSkyMaterial
	if sky_mat:
		_sim_material.set_shader_parameter("sky_color", sky_mat.sky_horizon_color.lerp(sky_mat.sky_top_color, 0.5))
		_sim_material.set_shader_parameter("ground_color", sky_mat.ground_bottom_color)


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
	_attributes.dof_blur_far_distance = focus + dof_sharp_band
	_attributes.dof_blur_far_transition = dof_transition
	_attributes.dof_blur_near_distance = maxf(focus - dof_sharp_band, 0.02)
	_attributes.dof_blur_near_transition = dof_transition


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
	add_child(root)
	for e in edges:
		var mi := MeshInstance3D.new()
		mi.mesh = bar
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = e[0]
		mi.rotation = e[1]
		root.add_child(mi)
