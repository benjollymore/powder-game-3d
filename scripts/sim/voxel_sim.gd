extends Node3D
## Owns the 128^3 voxel world on the GPU and advances it when TimeController
## hands out ticks.
##
## The world is a single RGBA8 3D texture (one byte per channel: R = element
## id, G = per-voxel seed, B/A reserved) created on the *global* RenderingDevice
## so the raymarch material can sample it through Texture3DRD with no copies.
## RGBA8 rather than R32_UINT because Texture3DRD only accepts formats that map
## to an Image format, and unorm8 round-trips bytes exactly.
##
## Every RenderingDevice call runs on the render thread through
## RenderingServer.call_on_render_thread; the main thread only queues work.
##
## Size comes from VoxelCodec.GRID (project setting `powder/sim/grid_size`,
## `grid=N` override) and every dispatch size derives from it; compute shaders
## receive it as a specialization constant. Measured with tools/bench.gd
## (--disable-vsync, M5 Pro, 1600x900 Retina, display-capped at ~11 ms):
##   128^3: 8 ticks/frame stays at the cap.
##   256^3: 0-2 ticks/frame at the cap, 4 ticks 15 ms, ~2.05 ms per tick.

signal readback_ready(bytes: PackedByteArray)
signal occupancy_ready(bytes: PackedByteArray)
signal density_ready(bytes: PackedByteArray)
signal scenario_changed(name: String)
signal velocity_ready(bytes: PackedByteArray)

var GRID: int = VoxelCodec.GRID
## Scene units are metres; every voxel is one centimetre, so the box is
## GRID cm across (1.28 m at 128, 2.56 m at 256).
const METRES_PER_VOXEL := 0.01
const SIM_SHADER_PATH := "res://shaders/compute/sim.glsl"
const BRUSH_SHADER_PATH := "res://shaders/compute/brush.glsl"
const BRUSH_LOCAL_SIZE := 8
const HYDRO_SHADER_PATH := "res://shaders/compute/hydro.glsl"
## Percent of the gap to a horizontal run's mean closed per hydro pass.
const HYDRO_RELAX_PERCENT := 50
const DENSITY_SHADER_PATH := "res://shaders/compute/density.glsl"
const AIR_SHADER_DIR := "res://shaders/compute/air/"
const AIR_KERNELS := ["air_downsample", "air_advect", "air_divergence", "air_jacobi", "air_project"]
## Coarse air grid: AIR_SUB^3 voxels per cell, 4^3 threads per workgroup.
const AIR_SUB := 4
var AIR_GRID: int = GRID / AIR_SUB
var AIR_GROUPS: int = AIR_GRID / 4
const RULE_NO_AIR := 4
const OCCUPANCY_SHADER_PATH := "res://shaders/compute/occupancy.glsl"
## One occupancy cell per 8^3 brick.
const BRICK := 8
var OCCUPANCY_GRID: int = GRID / BRICK

enum BrushMode { REPLACE, ONLY_AIR, ERASE, BOX }
## 2x2x2 blocks with a partition offset straddle the edge: GRID/2 + 1 blocks
## per axis, 4x4x4 threads per workgroup.
var DISPATCH_GROUPS: int = ceili((GRID / 2 + 1) / 4.0)
## Push constants: uvec4 a (tick, seed, substep, flags) + uvec4 b (offset xyz, 0).
const PUSH_CONSTANT_INTS := 8
## Brush push constants: ivec4 center/lo + radius, uvec4 element/mode/seed/amount, ivec4 box hi.
const BRUSH_PUSH_INTS := 12

@export var mesh_path: NodePath = ^"Mesh"
@export var world_seed := 12345
## Set by TimeController normally; tests drive ticks directly.
@export var listen_to_time_controller := true
## Bit flags passed to the kernel: 1 = no reactions, 2 = no decay (tests).
@export var rule_flags := 0
## Run the line-based liquid pressure solver after each tick.
@export var hydro_enabled := true
## Run the coarse air (velocity/pressure) solver once per tick batch.
@export var air_enabled := true
@export var jacobi_iterations := 20
@export var air_buoyancy := 0.03
@export var air_drag := 0.01
@export var air_max_speed := 1.5
## Preset world loaded at start and by R / Reload. `scenario=Name` on the
## command line (after `--`) overrides it.
@export var current_scenario := Scenarios.DEFAULT

var tick := 0

var _rd: RenderingDevice
var _grid_rid := RID()
var _texture := Texture3DRD.new()
var _material: ShaderMaterial
var _rt_ready := false

var _sim_shader := RID()
var _sim_pipeline := RID()
var _sim_set := RID()
var _brush_shader := RID()
var _brush_pipeline := RID()
var _brush_set := RID()
var _hydro_shader := RID()
var _hydro_pipeline := RID()
var _hydro_set := RID()
var _air_vel := [RID(), RID()]
var _air_pres := [RID(), RID()]
var _air_div := RID()
var _air_occ := RID()
var _air_src := RID()
var _air_sampler := RID()
var _air_shaders := {}
var _air_pipelines := {}
var _air_sets := {}
var _density_rid := RID()
var _density_texture := Texture3DRD.new()
var _density_shader := RID()
var _density_pipeline := RID()
var _density_set := RID()
var _occ_rid := RID()
var _occ_texture := Texture3DRD.new()
var _occ_shader := RID()
var _occ_pipeline := RID()
var _occ_set := RID()
var _elements_buffer := RID()
var _reactions_buffer := RID()


## Box edge length in scene units for the current grid.
static func world_size() -> float:
	return VoxelCodec.GRID * METRES_PER_VOXEL


func _ready() -> void:
	add_to_group("sim")
	scale = Vector3.ONE * world_size()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("scenario="):
			current_scenario = arg.substr(9)
	var mesh: MeshInstance3D = get_node(mesh_path)
	_material = mesh.material_override
	_material.set_shader_parameter("grid_size", GRID)
	_material.set_shader_parameter("palette", Elements.palette())
	_material.set_shader_parameter("liquid_mask", Elements.liquid_mask())
	_material.set_shader_parameter("gas_mask", Elements.gas_mask())
	_material.set_shader_parameter("extinction", Elements.extinction())
	_material.set_shader_parameter("liquid_full", float(Elements.LIQUID_FULL))
	_material.set_shader_parameter("density", _density_texture)
	# Bound now, but only points at a real texture once the render thread has
	# created it (see _process). Re-bound every run because the RD texture
	# binding does not survive scene reloads.
	_material.set_shader_parameter("voxels", _texture)
	_material.set_shader_parameter("occupancy", _occ_texture)
	_material.set_shader_parameter("brick_size", GRID / OCCUPANCY_GRID)
	RenderingServer.call_on_render_thread(_rt_init)
	# The first world is built on the GPU right after the textures exist.
	RenderingServer.call_on_render_thread(_rt_run_ops.bind(Scenarios.ops(current_scenario)))
	if listen_to_time_controller:
		TimeController.ticks_requested.connect(request_ticks)


func _exit_tree() -> void:
	# Detach the material's view first, otherwise the renderer rebuilds its
	# uniform set against a freed texture at shutdown.
	_texture.texture_rd_rid = RID()
	_occ_texture.texture_rd_rid = RID()
	_density_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_rt_free)


func _process(_delta: float) -> void:
	if _rt_ready and _texture.texture_rd_rid != _grid_rid:
		_texture.texture_rd_rid = _grid_rid
		_occ_texture.texture_rd_rid = _occ_rid
		_density_texture.texture_rd_rid = _density_rid


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_F5:
			RenderingServer.call_on_render_thread(_rt_build_pipelines.bind(true))
		KEY_F9:
			request_readback(_print_histogram)
		KEY_C:
			clear()
		KEY_R:
			load_scenario(current_scenario)
		_:
			return
	get_viewport().set_input_as_handled()


# --- public API (main thread) --------------------------------------------------

## Run `count` ticks this frame (each is one compute dispatch).
func request_ticks(count: int) -> void:
	if count <= 0 or not _rt_ready:
		return
	RenderingServer.call_on_render_thread(_rt_tick.bind(tick, count))
	tick += count


## Paint a sphere of `element` (voxel units). Runs this frame, before any ticks
## queued after it, so painting works while time is frozen.
func paint(center: Vector3i, radius: int, element: int, mode: BrushMode = BrushMode.REPLACE) -> void:
	if not _rt_ready:
		return
	var seed := randi() & 0x7FFFFFFF
	RenderingServer.call_on_render_thread(_rt_paint.bind(center, radius, element, mode, seed))


## Replace the whole world. `bytes` is GRID^3 * 4 bytes, x fastest.
func upload(bytes: PackedByteArray) -> void:
	assert(bytes.size() == GRID * GRID * GRID * 4)
	RenderingServer.call_on_render_thread(_rt_upload.bind(bytes))
	tick = 0
	TimeController.reset_tick_counter()


func clear() -> void:
	RenderingServer.call_on_render_thread(_rt_clear)
	tick = 0
	TimeController.reset_tick_counter()


## Copy the world back to the CPU. `callback` receives the PackedByteArray on the
## main thread (next frame). Stalls the GPU; debug and tests only.
func request_readback(callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_rt_readback.bind(callback))


## Fetch the 16^3 occupancy grid (one byte per brick, x fastest) without
## stalling; `occupancy_ready` fires on the main thread when it arrives.
func request_occupancy_readback() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_occupancy_readback)


## Copy the air velocity field (32^3 RGBA16F: xyz voxels/tick, w heat) back;
## `velocity_ready` fires on the main thread. Stalls the GPU; tests only.
func request_velocity_readback() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_velocity_readback)


## Decode one air cell from a velocity readback.
static func velocity_at(bytes: PackedByteArray, x: int, y: int, z: int) -> Vector4:
	var n := VoxelCodec.GRID / AIR_SUB
	var base := (x + n * (y + n * z)) * 8
	return Vector4(bytes.decode_half(base), bytes.decode_half(base + 2), bytes.decode_half(base + 4), bytes.decode_half(base + 6))


## Fetch the liquid density field (one byte per voxel) without stalling;
## `density_ready` fires on the main thread when it arrives.
func request_density_readback() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_density_readback)


## Count voxels per element id from a readback.
static func histogram(bytes: PackedByteArray) -> PackedInt64Array:
	var counts := PackedInt64Array()
	counts.resize(256)
	var n := bytes.size() / 4
	for i in n:
		counts[bytes[i * 4]] += 1
	return counts


## Total liquid amount (sum of byte z) held by cells of element `id`.
static func mass(bytes: PackedByteArray, id: int) -> int:
	var total := 0
	var n := bytes.size() / 4
	for i in n:
		if bytes[i * 4] == id:
			total += bytes[i * 4 + 2]
	return total


# --- render thread -------------------------------------------------------------

func _rt_init() -> void:
	_rd = RenderingServer.get_rendering_device()
	assert(_rd != null, "No RenderingDevice: needs Forward+/Mobile renderer and a window (not --headless)")

	var fmt := RDTextureFormat.new()
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = GRID
	fmt.height = GRID
	fmt.depth = GRID
	fmt.mipmaps = 1
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	_grid_rid = _rd.texture_create(fmt, RDTextureView.new())
	_rd.texture_clear(_grid_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)

	var props := Elements.property_bytes()
	_elements_buffer = _rd.storage_buffer_create(props.size(), props)
	var reacts := Elements.reaction_bytes()
	_reactions_buffer = _rd.storage_buffer_create(reacts.size(), reacts)

	var occ_fmt := RDTextureFormat.new()
	occ_fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	occ_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	occ_fmt.width = OCCUPANCY_GRID
	occ_fmt.height = OCCUPANCY_GRID
	occ_fmt.depth = OCCUPANCY_GRID
	occ_fmt.mipmaps = 1
	occ_fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	_occ_rid = _rd.texture_create(occ_fmt, RDTextureView.new())

	var den_fmt := RDTextureFormat.new()
	den_fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	den_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	den_fmt.width = GRID
	den_fmt.height = GRID
	den_fmt.depth = GRID
	den_fmt.mipmaps = 1
	den_fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	)
	_density_rid = _rd.texture_create(den_fmt, RDTextureView.new())

	for i in 2:
		_air_vel[i] = _rt_air_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
		_air_pres[i] = _rt_air_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT)
	_air_div = _rt_air_texture(RenderingDevice.DATA_FORMAT_R16_SFLOAT)
	_air_occ = _rt_air_texture(RenderingDevice.DATA_FORMAT_R8_UNORM)
	_air_src = _rt_air_texture(RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	var ss := RDSamplerState.new()
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	ss.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_air_sampler = _rd.sampler_create(ss)

	_rt_build_pipelines(false)
	_rt_occupancy_update()
	_rt_ready = true


func _rt_air_texture(format: RenderingDevice.DataFormat) -> RID:
	var fmt := RDTextureFormat.new()
	fmt.format = format
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.width = AIR_GRID
	fmt.height = AIR_GRID
	fmt.depth = AIR_GRID
	fmt.mipmaps = 1
	fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	var rid := _rd.texture_create(fmt, RDTextureView.new())
	_rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	return rid


func _sampler_uniform(binding: int, texture: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = binding
	u.add_id(_air_sampler)
	u.add_id(texture)
	return u


## Compile a compute shader. `from_source` reads the .glsl from disk so edits
## apply without restarting (the imported RDShaderFile keeps its old SPIR-V
## until the editor re-imports it).
func _rt_compile(path: String, from_source: bool) -> RDShaderSPIRV:
	var spirv: RDShaderSPIRV
	if from_source:
		var src := RDShaderSource.new()
		src.source_compute = FileAccess.get_file_as_string(path).replace("#[compute]", "")
		spirv = _rd.shader_compile_spirv_from_source(src)
	else:
		var file: RDShaderFile = load(path)
		spirv = file.get_spirv()
	if spirv.compile_error_compute != "":
		push_error("%s: %s" % [path.get_file(), spirv.compile_error_compute])
		return null
	return spirv


## Specialization constants baked into a compute pipeline at creation.
func _spec(values: Array) -> Array:
	var out: Array = []
	for i in values.size():
		var sc := RDPipelineSpecializationConstant.new()
		sc.constant_id = i
		sc.value = values[i]
		out.append(sc)
	return out


func _image_uniform(binding: int, rid: RID = _grid_rid) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	u.binding = binding
	u.add_id(rid)
	return u


func _buffer_uniform(binding: int, rid: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(rid)
	return u


## (Re)create both compute pipelines and their uniform sets. Uniform sets are
## created once here and reused every frame (per-frame RD object creation
## leaks on Metal).
func _rt_build_pipelines(from_source: bool) -> void:
	var sim_spirv := _rt_compile(SIM_SHADER_PATH, from_source)
	var brush_spirv := _rt_compile(BRUSH_SHADER_PATH, from_source)
	var occ_spirv := _rt_compile(OCCUPANCY_SHADER_PATH, from_source)
	var hydro_spirv := _rt_compile(HYDRO_SHADER_PATH, from_source)
	var density_spirv := _rt_compile(DENSITY_SHADER_PATH, from_source)
	if sim_spirv == null or brush_spirv == null or occ_spirv == null or hydro_spirv == null or density_spirv == null:
		return
	var air_spirv := {}
	for k in AIR_KERNELS:
		var sp := _rt_compile(AIR_SHADER_DIR + k + ".glsl", from_source)
		if sp == null:
			return
		air_spirv[k] = sp
	_rt_free_pipelines()

	_sim_shader = _rd.shader_create_from_spirv(sim_spirv)
	_sim_pipeline = _rd.compute_pipeline_create(_sim_shader, _spec([GRID]))
	var u_elems := RDUniform.new()
	u_elems.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_elems.binding = 1
	u_elems.add_id(_elements_buffer)
	var u_reacts := RDUniform.new()
	u_reacts.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_reacts.binding = 2
	u_reacts.add_id(_reactions_buffer)
	_sim_set = _rd.uniform_set_create(
		[_image_uniform(0), u_elems, u_reacts, _sampler_uniform(3, _air_vel[0])], _sim_shader, 0)

	# Air solver: downsample -> advect (vel0 -> vel1) -> divergence -> jacobi
	# (pres ping-pong, even count so the result lands in pres0) -> project (vel1 -> vel0).
	for k in AIR_KERNELS:
		_air_shaders[k] = _rd.shader_create_from_spirv(air_spirv[k])
		_air_pipelines[k] = _rd.compute_pipeline_create(_air_shaders[k], _spec([AIR_GRID, AIR_SUB]))
	_air_sets["air_downsample"] = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _air_occ), _image_uniform(2, _air_src), _buffer_uniform(3, _elements_buffer)],
		_air_shaders["air_downsample"], 0)
	_air_sets["air_advect"] = _rd.uniform_set_create(
		[_sampler_uniform(0, _air_vel[0]), _image_uniform(1, _air_occ), _image_uniform(2, _air_src), _image_uniform(3, _air_vel[1])],
		_air_shaders["air_advect"], 0)
	_air_sets["air_divergence"] = _rd.uniform_set_create(
		[_image_uniform(0, _air_vel[1]), _image_uniform(1, _air_occ), _image_uniform(2, _air_div)],
		_air_shaders["air_divergence"], 0)
	for i in 2:
		_air_sets["air_jacobi%d" % i] = _rd.uniform_set_create(
			[_image_uniform(0, _air_pres[i]), _image_uniform(1, _air_div), _image_uniform(2, _air_occ), _image_uniform(3, _air_pres[1 - i])],
			_air_shaders["air_jacobi"], 0)
	_air_sets["air_project"] = _rd.uniform_set_create(
		[_image_uniform(0, _air_vel[1]), _image_uniform(1, _air_pres[0]), _image_uniform(2, _air_occ), _image_uniform(3, _air_vel[0])],
		_air_shaders["air_project"], 0)

	_brush_shader = _rd.shader_create_from_spirv(brush_spirv)
	_brush_pipeline = _rd.compute_pipeline_create(_brush_shader, _spec([GRID]))
	_brush_set = _rd.uniform_set_create([_image_uniform(0)], _brush_shader, 0)

	_hydro_shader = _rd.shader_create_from_spirv(hydro_spirv)
	_hydro_pipeline = _rd.compute_pipeline_create(_hydro_shader, _spec([GRID]))
	_hydro_set = _rd.uniform_set_create([_image_uniform(0), _buffer_uniform(1, _elements_buffer)], _hydro_shader, 0)

	_density_shader = _rd.shader_create_from_spirv(density_spirv)
	_density_pipeline = _rd.compute_pipeline_create(_density_shader)
	_density_set = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _density_rid), _buffer_uniform(2, _elements_buffer)], _density_shader, 0)

	_occ_shader = _rd.shader_create_from_spirv(occ_spirv)
	_occ_pipeline = _rd.compute_pipeline_create(_occ_shader)
	_occ_set = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _occ_rid), _buffer_uniform(2, _elements_buffer)], _occ_shader, 0)
	if from_source:
		print("compute shaders reloaded")


func _rt_free_pipelines() -> void:
	for rid in [_sim_set, _sim_pipeline, _sim_shader, _brush_set, _brush_pipeline, _brush_shader,
			_occ_set, _occ_pipeline, _occ_shader, _hydro_set, _hydro_pipeline, _hydro_shader,
			_density_set, _density_pipeline, _density_shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_sim_set = RID()
	_sim_pipeline = RID()
	_sim_shader = RID()
	_brush_set = RID()
	_brush_pipeline = RID()
	_brush_shader = RID()
	_occ_set = RID()
	_occ_pipeline = RID()
	_occ_shader = RID()
	_hydro_set = RID()
	_hydro_pipeline = RID()
	_hydro_shader = RID()
	_density_set = RID()
	_density_pipeline = RID()
	_density_shader = RID()
	for d in [_air_sets, _air_pipelines, _air_shaders]:
		for k in d:
			if d[k].is_valid():
				_rd.free_rid(d[k])
		d.clear()


func _rt_free() -> void:
	_rt_free_pipelines()
	for rid in [_elements_buffer, _reactions_buffer, _grid_rid, _occ_rid, _density_rid,
			_air_vel[0], _air_vel[1], _air_pres[0], _air_pres[1], _air_div, _air_occ, _air_src, _air_sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_elements_buffer = RID()
	_reactions_buffer = RID()
	_grid_rid = RID()
	_occ_rid = RID()
	_density_rid = RID()
	_rt_ready = false


func _rt_tick(first_tick: int, count: int) -> void:
	if not _sim_pipeline.is_valid():
		return
	var cl := _rd.compute_list_begin()
	if air_enabled:
		_rt_air_step(cl, count, first_tick)
	var push := PackedInt32Array()
	push.resize(PUSH_CONSTANT_INTS)
	var hydro_groups := GRID / 8  # 8x8 threads per group, one line per thread
	for i in count:
		var t := first_tick + i
		var offset := partition_offset(t)
		push[0] = t
		push[1] = world_seed
		push[2] = i
		push[3] = rule_flags | (0 if air_enabled else RULE_NO_AIR)
		push[4] = offset.x
		push[5] = offset.y
		push[6] = offset.z
		push[7] = Elements.REACTIONS.size()
		var bytes := push.to_byte_array()
		_rd.compute_list_bind_compute_pipeline(cl, _sim_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _sim_set, 0)
		_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
		_rd.compute_list_dispatch(cl, DISPATCH_GROUPS, DISPATCH_GROUPS, DISPATCH_GROUPS)
		_rd.compute_list_add_barrier(cl)
		if not hydro_enabled:
			continue
		# Liquid pressure: exact columns, then relax rows along x or z alternately.
		_rd.compute_list_bind_compute_pipeline(cl, _hydro_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _hydro_set, 0)
		for mode in [0, 1 + (t & 1)]:
			var hp := PackedInt32Array([mode, t, world_seed, HYDRO_RELAX_PERCENT]).to_byte_array()
			_rd.compute_list_set_push_constant(cl, hp, hp.size())
			_rd.compute_list_dispatch(cl, hydro_groups, hydro_groups, 1)
			_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()
	_rt_occupancy_update()


## One air-solver step covering `dt` ticks, recorded into an open compute list.
func _rt_air_step(cl: int, dt: int, tick_now: int) -> void:
	if not _air_pipelines.has("air_project"):
		return
	var params := PackedFloat32Array([float(dt), air_buoyancy, air_drag, air_max_speed]).to_byte_array()
	params.append_array(PackedInt32Array([tick_now, 0, 0, 0]).to_byte_array())
	var iters := jacobi_iterations + (jacobi_iterations & 1) # even, so the result is in pres0
	var order: Array = ["air_downsample", "air_advect", "air_divergence"]
	for i in iters:
		order.append("air_jacobi%d" % (i & 1))
	order.append("air_project")
	for step in order:
		var kernel: String = step.trim_suffix("0").trim_suffix("1") if step.begins_with("air_jacobi") else step
		_rd.compute_list_bind_compute_pipeline(cl, _air_pipelines[kernel])
		_rd.compute_list_bind_uniform_set(cl, _air_sets[step], 0)
		_rd.compute_list_set_push_constant(cl, params, params.size())
		_rd.compute_list_dispatch(cl, AIR_GROUPS, AIR_GROUPS, AIR_GROUPS)
		_rd.compute_list_add_barrier(cl)


func _rt_velocity_readback() -> void:
	var bytes := _rd.texture_get_data(_air_vel[0], 0)
	velocity_ready.emit.call_deferred(bytes)


func _rt_air_clear() -> void:
	for rid in [_air_vel[0], _air_vel[1], _air_pres[0], _air_pres[1]]:
		if rid.is_valid():
			_rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)


## Which of the 8 Margolus partitions to use on a given tick. Hashed rather
## than cycled so no direction is systematically favoured.
static func partition_offset(t: int) -> Vector3i:
	var h := (t * 2654435761) & 0xFFFFFFFF
	h ^= h >> 15
	h = (h * 2246822519) & 0xFFFFFFFF
	h ^= h >> 13
	return Vector3i(h & 1, (h >> 1) & 1, (h >> 2) & 1)


func _rt_paint(center: Vector3i, radius: int, element: int, mode: int, seed: int) -> void:
	if not _brush_pipeline.is_valid():
		return
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
	_rt_brush_sphere(cl, center, radius, element, mode, seed, Elements.default_amount(element))
	_rd.compute_list_end()
	_rt_occupancy_update()


func _rt_brush_sphere(cl: int, center: Vector3i, radius: int, element: int, mode: int, seed: int, amount: int) -> void:
	var groups := ceili(float(2 * radius + 1) / BRUSH_LOCAL_SIZE)
	var push := PackedInt32Array([center.x, center.y, center.z, radius, element, mode, seed, amount, 0, 0, 0, 0])
	var bytes := push.to_byte_array()
	_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
	_rd.compute_list_dispatch(cl, groups, groups, groups)
	_rd.compute_list_add_barrier(cl)


func _rt_brush_box(cl: int, lo: Vector3i, hi: Vector3i, element: int, seed: int, amount: int) -> void:
	var size := (hi - lo).max(Vector3i.ZERO)
	if size.x == 0 or size.y == 0 or size.z == 0:
		return
	var push := PackedInt32Array([lo.x, lo.y, lo.z, 0, element, BrushMode.BOX, seed, amount, hi.x, hi.y, hi.z, 0])
	var bytes := push.to_byte_array()
	_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
	_rd.compute_list_dispatch(cl, ceili(size.x / float(BRUSH_LOCAL_SIZE)), ceili(size.y / float(BRUSH_LOCAL_SIZE)), ceili(size.z / float(BRUSH_LOCAL_SIZE)))
	_rd.compute_list_add_barrier(cl)


## Clear the world and replay scenario ops (see Scenarios.ops) on the GPU.
func _rt_run_ops(ops: Array) -> void:
	if not _brush_pipeline.is_valid():
		return
	_rd.texture_clear(_grid_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_rt_air_clear()
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
	var seed := 1
	for op in ops:
		seed += 7919
		if op["type"] == "box":
			_rt_brush_box(cl, op["lo"], op["hi"], op["id"], seed, op["amount"])
		else:
			var c: Vector3 = op["center"]
			_rt_brush_sphere(cl, Vector3i(c.round()), int(round(op["radius"])), op["id"], BrushMode.REPLACE, seed, op["amount"])
	_rd.compute_list_end()
	_rt_occupancy_update()


func _rt_upload(bytes: PackedByteArray) -> void:
	_rd.texture_update(_grid_rid, 0, bytes)
	_rt_air_clear()
	_rt_occupancy_update()


func _rt_clear() -> void:
	_rd.texture_clear(_grid_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_rt_air_clear()
	_rt_occupancy_update()


## Recompute everything derived from the voxel texture: the coarse occupancy
## grid and the liquid density field the renderer samples.
func _rt_occupancy_update() -> void:
	if not _occ_pipeline.is_valid():
		return
	var groups := OCCUPANCY_GRID / 4
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _occ_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _occ_set, 0)
	_rd.compute_list_dispatch(cl, groups, groups, groups)
	_rd.compute_list_add_barrier(cl)
	if _density_pipeline.is_valid():
		var dg := GRID / 8
		_rd.compute_list_bind_compute_pipeline(cl, _density_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _density_set, 0)
		_rd.compute_list_dispatch(cl, dg, dg, dg)
	_rd.compute_list_end()


func _rt_density_readback() -> void:
	_rd.texture_get_data_async(_density_rid, 0, _on_density_bytes)


func _on_density_bytes(bytes: PackedByteArray) -> void:
	density_ready.emit.call_deferred(bytes)


func _rt_occupancy_readback() -> void:
	_rd.texture_get_data_async(_occ_rid, 0, _on_occupancy_bytes)


func _on_occupancy_bytes(bytes: PackedByteArray) -> void:
	occupancy_ready.emit.call_deferred(bytes)


func _rt_readback(callback: Callable) -> void:
	var bytes := _rd.texture_get_data(_grid_rid, 0)
	callback.call_deferred(bytes)
	readback_ready.emit.call_deferred(bytes)


# --- debug / test data -----------------------------------------------------------

func _print_histogram(bytes: PackedByteArray) -> void:
	var counts := histogram(bytes)
	var parts := PackedStringArray()
	for id in Elements.count():
		if counts[id] > 0:
			parts.append("%s=%d" % [Elements.TABLE[id]["name"], counts[id]])
	print("tick %d  %s" % [tick, "  ".join(parts)])


## The world bytes for the current scenario (see Scenarios).
func build_test_pattern() -> PackedByteArray:
	return Scenarios.build(current_scenario)


## Build a preset world on the GPU (box and sphere fills), no CPU voxel loops.
func load_scenario(name: String) -> void:
	current_scenario = name
	RenderingServer.call_on_render_thread(_rt_run_ops.bind(Scenarios.ops(name)))
	tick = 0
	TimeController.reset_tick_counter()
	scenario_changed.emit(name)
