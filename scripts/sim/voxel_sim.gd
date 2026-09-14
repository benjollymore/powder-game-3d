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

signal readback_ready(bytes: PackedByteArray)
signal occupancy_ready(bytes: PackedByteArray)

const GRID := VoxelCodec.GRID
const SIM_SHADER_PATH := "res://shaders/compute/sim.glsl"
const BRUSH_SHADER_PATH := "res://shaders/compute/brush.glsl"
const BRUSH_LOCAL_SIZE := 8
const OCCUPANCY_SHADER_PATH := "res://shaders/compute/occupancy.glsl"
## One occupancy cell per 8^3 brick: 16^3 cells for a 128^3 world.
const OCCUPANCY_GRID := 16

enum BrushMode { REPLACE, ONLY_AIR, ERASE }
## 2x2x2 blocks with a partition offset straddle the edge: 65 blocks per axis,
## 4x4x4 threads per workgroup -> 17 groups per axis.
const DISPATCH_GROUPS := 17
## Push constants: uvec4 a (tick, seed, substep, flags) + uvec4 b (offset xyz, 0).
const PUSH_CONSTANT_INTS := 8

@export var mesh_path: NodePath = ^"Mesh"
@export var world_seed := 12345
## Set by TimeController normally; tests drive ticks directly.
@export var listen_to_time_controller := true
## Bit flags passed to the kernel: 1 = no reactions, 2 = no decay (tests).
@export var rule_flags := 0

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
var _occ_rid := RID()
var _occ_texture := Texture3DRD.new()
var _occ_shader := RID()
var _occ_pipeline := RID()
var _occ_set := RID()
var _elements_buffer := RID()
var _reactions_buffer := RID()


func _ready() -> void:
	var mesh: MeshInstance3D = get_node(mesh_path)
	_material = mesh.material_override
	_material.set_shader_parameter("grid_size", GRID)
	_material.set_shader_parameter("palette", Elements.palette())
	# Bound now, but only points at a real texture once the render thread has
	# created it (see _process). Re-bound every run because the RD texture
	# binding does not survive scene reloads.
	_material.set_shader_parameter("voxels", _texture)
	_material.set_shader_parameter("occupancy", _occ_texture)
	_material.set_shader_parameter("brick_size", GRID / OCCUPANCY_GRID)
	RenderingServer.call_on_render_thread(_rt_init.bind(build_test_pattern()))
	if listen_to_time_controller:
		TimeController.ticks_requested.connect(request_ticks)


func _exit_tree() -> void:
	# Detach the material's view first, otherwise the renderer rebuilds its
	# uniform set against a freed texture at shutdown.
	_texture.texture_rd_rid = RID()
	_occ_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_rt_free)


func _process(_delta: float) -> void:
	if _rt_ready and _texture.texture_rd_rid != _grid_rid:
		_texture.texture_rd_rid = _grid_rid
		_occ_texture.texture_rd_rid = _occ_rid


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
			upload(build_test_pattern())
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


## Count voxels per element id from a readback.
static func histogram(bytes: PackedByteArray) -> PackedInt64Array:
	var counts := PackedInt64Array()
	counts.resize(256)
	var n := bytes.size() / 4
	for i in n:
		counts[bytes[i * 4]] += 1
	return counts


# --- render thread -------------------------------------------------------------

func _rt_init(initial: PackedByteArray) -> void:
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
	_grid_rid = _rd.texture_create(fmt, RDTextureView.new(), [initial])

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

	_rt_build_pipelines(false)
	_rt_occupancy_update()
	_rt_ready = true


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
	if sim_spirv == null or brush_spirv == null or occ_spirv == null:
		return
	_rt_free_pipelines()

	_sim_shader = _rd.shader_create_from_spirv(sim_spirv)
	_sim_pipeline = _rd.compute_pipeline_create(_sim_shader)
	var u_elems := RDUniform.new()
	u_elems.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_elems.binding = 1
	u_elems.add_id(_elements_buffer)
	var u_reacts := RDUniform.new()
	u_reacts.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u_reacts.binding = 2
	u_reacts.add_id(_reactions_buffer)
	_sim_set = _rd.uniform_set_create([_image_uniform(0), u_elems, u_reacts], _sim_shader, 0)

	_brush_shader = _rd.shader_create_from_spirv(brush_spirv)
	_brush_pipeline = _rd.compute_pipeline_create(_brush_shader)
	_brush_set = _rd.uniform_set_create([_image_uniform(0)], _brush_shader, 0)

	_occ_shader = _rd.shader_create_from_spirv(occ_spirv)
	_occ_pipeline = _rd.compute_pipeline_create(_occ_shader)
	_occ_set = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _occ_rid), _buffer_uniform(2, _elements_buffer)], _occ_shader, 0)
	if from_source:
		print("compute shaders reloaded")


func _rt_free_pipelines() -> void:
	for rid in [_sim_set, _sim_pipeline, _sim_shader, _brush_set, _brush_pipeline, _brush_shader,
			_occ_set, _occ_pipeline, _occ_shader]:
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


func _rt_free() -> void:
	_rt_free_pipelines()
	for rid in [_elements_buffer, _reactions_buffer, _grid_rid, _occ_rid]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_elements_buffer = RID()
	_reactions_buffer = RID()
	_grid_rid = RID()
	_occ_rid = RID()
	_rt_ready = false


func _rt_tick(first_tick: int, count: int) -> void:
	if not _sim_pipeline.is_valid():
		return
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _sim_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _sim_set, 0)
	var push := PackedInt32Array()
	push.resize(PUSH_CONSTANT_INTS)
	for i in count:
		var t := first_tick + i
		var offset := partition_offset(t)
		push[0] = t
		push[1] = world_seed
		push[2] = i
		push[3] = rule_flags
		push[4] = offset.x
		push[5] = offset.y
		push[6] = offset.z
		push[7] = Elements.REACTIONS.size()
		var bytes := push.to_byte_array()
		_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
		_rd.compute_list_dispatch(cl, DISPATCH_GROUPS, DISPATCH_GROUPS, DISPATCH_GROUPS)
		_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()
	_rt_occupancy_update()


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
	var groups := ceili(float(2 * radius + 1) / BRUSH_LOCAL_SIZE)
	var push := PackedInt32Array([center.x, center.y, center.z, radius, element, mode, seed, 0])
	var bytes := push.to_byte_array()
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
	_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
	_rd.compute_list_dispatch(cl, groups, groups, groups)
	_rd.compute_list_end()
	_rt_occupancy_update()


func _rt_upload(bytes: PackedByteArray) -> void:
	_rd.texture_update(_grid_rid, 0, bytes)
	_rt_occupancy_update()


func _rt_clear() -> void:
	_rd.texture_clear(_grid_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_rt_occupancy_update()


## Recompute the coarse occupancy grid from the voxel texture.
func _rt_occupancy_update() -> void:
	if not _occ_pipeline.is_valid():
		return
	var groups := OCCUPANCY_GRID / 4
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _occ_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _occ_set, 0)
	_rd.compute_list_dispatch(cl, groups, groups, groups)
	_rd.compute_list_end()


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


## Demo world: wall floor, sand sphere, a wall bowl with a water cube dropping
## into it, a steam block that rises, and a plant checker.
func build_test_pattern() -> PackedByteArray:
	var data := PackedInt32Array()
	data.resize(GRID * GRID * GRID)
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed
	var c := Vector3(GRID * 0.5, GRID * 0.55, GRID * 0.5)
	var r2 := (GRID * 0.2) * (GRID * 0.2)
	for z in GRID:
		for y in GRID:
			for x in GRID:
				var id := Elements.Id.AIR
				if y < 4:
					id = Elements.Id.WALL
				elif Vector3(x, y, z).distance_squared_to(c) < r2:
					id = Elements.Id.SAND
				elif x >= 4 and x < 44 and z >= 4 and z < 44 and y < 30 \
						and not (x >= 6 and x < 42 and z >= 6 and z < 42 and y >= 6):
					id = Elements.Id.WALL
				elif x >= 10 and x < 34 and z >= 10 and z < 34 and y >= 60 and y < 84:
					id = Elements.Id.WATER
				elif x >= 84 and x < 104 and z >= 8 and z < 28 and y >= 8 and y < 28:
					id = Elements.Id.STEAM
				elif x >= 100 and x < 112 and z >= 100 and z < 112 and y >= 4 and y < 40:
					id = Elements.Id.PLANT  # trunk
				elif x >= 88 and x < 124 and z >= 88 and z < 124 and y >= 40 and y < 52 \
						and ((x / 4 + z / 4) % 2 == 0 or y < 44):
					id = Elements.Id.PLANT  # canopy
				elif x >= 96 and x < 100 and z >= 100 and z < 112 and y >= 4 and y < 8:
					id = Elements.Id.FIRE   # seed fire at the trunk base
				elif x >= 50 and x < 62 and z >= 100 and z < 124 and y >= 4 and y < 16:
					id = Elements.Id.OIL
				if id != Elements.Id.AIR:
					data[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, rng.randi_range(0, 255))
	return data.to_byte_array()
