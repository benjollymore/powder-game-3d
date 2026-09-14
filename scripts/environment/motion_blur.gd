@tool
class_name MotionBlurEffect
extends CompositorEffect
## Camera motion blur as a post-transparent compositor effect. Velocity comes
## from depth reprojection (this frame's depth against last frame's camera),
## not Godot's motion vectors: the raymarched voxel world writes its own depth
## and would otherwise carry the bounding cube's vectors, and reprojection
## from depth is exact for static geometry. Runs before tonemapping on the
## internal-resolution colour buffer. See shaders/post/motion_blur.glsl.

const SHADER_PATH := "res://shaders/post/motion_blur.glsl"

## Longest smear in internal-resolution pixels.
@export var max_blur_px := 16.0
## Fraction of a frame's movement that is smeared (shutter angle / 360).
@export var strength := 0.6
## Output velocity as colour instead of blurring.
@export var debug := false

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _camera_buffer := RID()
var _prev_view_proj: Array = []  # per view
var _sets := {}                  # keyed by colour texture RID


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_motion_vectors = false
	_rd = RenderingServer.get_rendering_device()
	RenderingServer.call_on_render_thread(_rt_init)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _rd:
		for rid in [_pipeline, _shader, _sampler, _camera_buffer]:
			if rid.is_valid():
				_rd.free_rid(rid)


func _rt_init() -> void:
	var file: RDShaderFile = load(SHADER_PATH)
	var spirv := file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("motion blur shader: " + spirv.compile_error_compute)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(ss)
	var zeros := PackedByteArray()
	zeros.resize(160)
	_camera_buffer = _rd.uniform_buffer_create(zeros.size(), zeros)


static func _mat_bytes(m: Projection) -> PackedByteArray:
	var f := PackedFloat32Array()
	for c in 4:
		var col: Vector4 = m[c]
		f.append_array([col.x, col.y, col.z, col.w])
	return f.to_byte_array()


func _render_callback(_type: int, render_data: RenderData) -> void:
	if not _pipeline.is_valid():
		return
	var buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene: RenderSceneDataRD = render_data.get_render_scene_data()
	if buffers == null or scene == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 or size.y == 0:
		return
	var views := buffers.get_view_count()
	if _prev_view_proj.size() != views:
		_prev_view_proj.resize(views)
	# Scratch copy of the colour buffer, same format, so the blur can read
	# neighbours while writing in place.
	var fmt := buffers.get_texture_format(&"render_buffers", &"color")
	var scratch_usage := (RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT)
	var scratch := buffers.create_texture(&"motion_blur", &"scratch", fmt.format, scratch_usage,
		RenderingDevice.TEXTURE_SAMPLES_1, size, views, 1, true, false)
	var cam_xform: Transform3D = scene.get_cam_transform()
	for view in views:
		var proj: Projection = scene.get_view_projection(view)
		var view_proj: Projection = proj * Projection(cam_xform.affine_inverse())
		var prev: Projection = _prev_view_proj[view] if _prev_view_proj[view] != null else view_proj
		_prev_view_proj[view] = view_proj
		var color := buffers.get_color_layer(view)
		var depth := buffers.get_depth_layer(view)
		var scratch_layer := buffers.get_texture_slice(&"motion_blur", &"scratch", view, 0, 1, 1)
		var bytes := _mat_bytes(view_proj.inverse())
		bytes.append_array(_mat_bytes(prev))
		bytes.append_array(PackedFloat32Array([size.x, size.y, max_blur_px, strength]).to_byte_array())
		bytes.append_array(PackedFloat32Array([1.0 if debug else 0.0, 0.0, 0.0, 0.0]).to_byte_array())
		_rd.buffer_update(_camera_buffer, 0, bytes.size(), bytes)
		var blur_set := _set_for(color, depth, scratch_layer)   # reads colour, writes scratch
		var copy_set := _set_for(scratch_layer, depth, color)   # reads scratch, writes colour
		var groups := Vector2i(ceili(size.x / 8.0), ceili(size.y / 8.0))
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _pipeline)
		for stage in 2:
			var push := PackedInt32Array([stage, 0, 0, 0]).to_byte_array()
			_rd.compute_list_bind_uniform_set(cl, blur_set if stage == 0 else copy_set, 0)
			_rd.compute_list_set_push_constant(cl, push, push.size())
			_rd.compute_list_dispatch(cl, groups.x, groups.y, 1)
			_rd.compute_list_add_barrier(cl)
		_rd.compute_list_end()


## Uniform sets (source sampled, depth sampled, destination image) are cached
## per texture triple; the RD invalidates them when buffers are recreated
## (resize), so a stale entry is just replaced.
func _set_for(src: RID, depth: RID, dst: RID) -> RID:
	var key := "%d_%d_%d" % [src.get_id(), depth.get_id(), dst.get_id()]
	if _sets.has(key) and _rd.uniform_set_is_valid(_sets[key]):
		return _sets[key]
	var u_src := RDUniform.new()
	u_src.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_src.binding = 0
	u_src.add_id(_sampler)
	u_src.add_id(src)
	var u_depth := RDUniform.new()
	u_depth.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u_depth.binding = 1
	u_depth.add_id(_sampler)
	u_depth.add_id(depth)
	var u_out := RDUniform.new()
	u_out.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u_out.binding = 2
	u_out.add_id(dst)
	var u_cam := RDUniform.new()
	u_cam.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	u_cam.binding = 3
	u_cam.add_id(_camera_buffer)
	var set := _rd.uniform_set_create([u_src, u_depth, u_out, u_cam], _shader, 0)
	_sets[key] = set
	return set
