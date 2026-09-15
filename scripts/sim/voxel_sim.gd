extends Node3D
## Owns the configurable voxel world on the GPU and advances it when TimeController
## hands out ticks.
##
## The world is a single RGBA8 3D texture (one byte per channel: R = element
## id, G = per-voxel seed, B = liquid amount, A = movement flags) created on the *global* RenderingDevice
## so the raymarch material can sample it through Texture3DRD with no copies.
## RGBA8 rather than R32_UINT because Texture3DRD only accepts formats that map
## to an Image format, and unorm8 round-trips bytes exactly.
##
## A second authoritative RG32F texture of the same extent is the thermal
## layer: R = temperature in kelvin, G = latent progress through a phase
## plateau. It is carried with material (swaps permute it), captured by
## regional history, and replaced or initialised by every whole-world path.
## See docs/milestone/heat-brief.md, contract 3.
##
## Every RenderingDevice call runs on the render thread through
## RenderingServer.call_on_render_thread; the main thread only queues work.
##
## Size comes from VoxelCodec.GRID (project setting `powder/sim/grid_size`,
## `grid=N` override) and every dispatch size derives from it; compute shaders
## receive it as a specialization constant. Current fixed-cadence timing
## evidence and its workload limits are in docs/milestone/simulation.md;
## old batch-dependent-air measurements do not describe this implementation.

signal readback_ready(bytes: PackedByteArray)
## Thermal layer readback: GRID^3 cells x 8 bytes (two float32 per cell, x fastest).
signal thermal_ready(bytes: PackedByteArray)
## Both authoritative layers read in one render-thread job, so they belong to
## the same tick (request_state_readback).
signal state_ready(voxels: PackedByteArray, thermal: PackedByteArray)
signal occupancy_ready(bytes: PackedByteArray)
signal density_ready(bytes: PackedByteArray)
signal scenario_changed(name: String)
signal velocity_ready(bytes: PackedByteArray)
signal splat_count_ready(count: int)
## Per-frame sprite counts: grains, leaves, droplets, spawn requests, fx claims, fx alive,
## then activity tallies (see splat_emit.glsl): 32 ints.
signal layer_counts_ready(counts: PackedInt32Array)
## Same 32 ints, fetched without stalling (see request_activity).
signal activity_ready(counts: PackedInt32Array)
signal edit_transaction_ready(result: Dictionary)
const EditGPU := preload("res://scripts/sim/voxel_edit_gpu.gd")
const ThermalStrokeSpacing := preload("res://scripts/editor/thermal_stroke.gd")
const EditGeometry := preload("res://scripts/discovery/edit_geometry.gd")
const GPUProfile := preload("res://scripts/sim/gpu_profile.gd")
var edit_epoch := 0 # reset boundary; ticks do not invalidate authored history
var edit_revision := 0 # ordered voxel edit submissions, distinct from tick
var _edit_sequence := 0
var _edit_epochs := {}
var _editor_gpu: RefCounted

var GRID: int = VoxelCodec.GRID
## Scene units are metres; every voxel is one centimetre, so the box is
## GRID cm across (1.28 m at 128, 2.56 m at 256).
const METRES_PER_VOXEL := 0.01
const SIM_SHADER_PATH := "res://shaders/compute/sim.glsl"
const BRUSH_SHADER_PATH := "res://shaders/compute/brush.glsl"
const BRUSH_LOCAL_SIZE := 8
const HYDRO_SHADER_PATH := "res://shaders/compute/hydro.glsl"
const THERMAL_INIT_SHADER_PATH := "res://shaders/compute/thermal_init.glsl"
## Thermal layer: float32 temperature (K) + float32 latent progress per cell.
const THERMAL_BYTES_PER_CELL := 8
const THERMAL_FORMAT := RenderingDevice.DATA_FORMAT_R32G32_SFLOAT
const THERMAL_IMAGE_FORMAT := Image.FORMAT_RGF
## Percent of the gap to a horizontal run's mean closed per hydro pass.
const HYDRO_RELAX_PERCENT := 50
const FIELDS_SHADER_PATH := "res://shaders/compute/fields.glsl"
const FIELDS_MIP_SHADER_PATH := "res://shaders/compute/fields_mip.glsl"
const FIELDS_MIPS := 5
const AIR_SHADER_DIR := "res://shaders/compute/air/"
const AIR_KERNELS := ["air_downsample", "air_advect", "air_divergence", "air_jacobi", "air_project"]
## Coarse air grid: AIR_SUB^3 voxels per cell, 4^3 threads per workgroup.
const AIR_SUB := 4
var AIR_GRID: int = GRID / AIR_SUB
var AIR_GROUPS: int = AIR_GRID / 4
const RULE_NO_AIR := 4
const RULE_NO_SPECIALS := 8 # clone, void and the gunpowder fuse
const OCCUPANCY_SHADER_PATH := "res://shaders/compute/occupancy.glsl"
const SUNVIS_SHADER_PATH := "res://shaders/compute/sunvis.glsl"
const SPLAT_SHADER_PATH := "res://shaders/compute/splat_emit.glsl"
const FX_SHADER_PATH := "res://shaders/compute/fx.glsl"
## Spawn requests the emit pass may queue per frame for the FX pool.
const FX_SPAWN_CAPACITY := 4096
## Sprite layers filled by the GPU, indexed by InstanceLayer.role.
enum Layer { GRAINS, LEAVES, DROPLETS, FX }
const LAYER_COUNT := 4
## Sprite/activity counter buffer: 32 uints (layout in splat_emit.glsl).
const COUNTER_BYTES := 128
## Indices into the activity part of the counters.
enum Activity { WATER = 8, FIRE = 12, STEAM = 16, LIQUID = 20 }
const SUNVIS_SLABS_PER_DISPATCH := 8
## The sun-visibility field is swept at half resolution (2 cm cells at 256^3).
const SUNVIS_DIV := 2
## Per-voxel light loss through gas for the sun-visibility sweep.
const SUNVIS_GAS_EXTINCTION := 0.12
## One occupancy cell per 8^3 brick.
const BRICK := 8
var OCCUPANCY_GRID: int = GRID / BRICK

## HEAT and COOL change only the thermal layer (strength in kelvin, radial
## falloff); see scripts/sim/brush.gd Mode, which mirrors this enum.
enum BrushMode { REPLACE, ONLY_AIR, ERASE, BOX, BOX_ONLY_AIR, HEAT, COOL }
## Brush shapes (docs/milestone/placement-brief.md contract 5); see
## scripts/sim/brush.gd Shape, which mirrors this enum. The disc's plane axis
## is the workplane axis for cell strokes and the picked face for surface stamps.
enum BrushShape { SPHERE, CUBE, DISC }
## 2x2x2 blocks with a partition offset straddle the edge: GRID/2 + 1 blocks
## per axis, 4x4x4 threads per workgroup.
var DISPATCH_GROUPS: int = ceili((GRID / 2 + 1) / 4.0)
## Push constants: uvec4 a (tick, seed, reserved, flags) + uvec4 b (offset xyz,
## reaction count) + uvec4 c (thermal dt, ambient, ignition chance as float bits, 0).
const PUSH_CONSTANT_INTS := 12
const RULE_NO_THERMAL := 16 # bit 8 is RULE_NO_SPECIALS
## Brush push constants: ivec4 center/lo + radius, uvec4 element/mode/seed/amount,
## ivec4 box hi (brush modes: x = shape, y = disc axis; heat/cool: w = strength bits).
const BRUSH_PUSH_INTS := 12

@export var mesh_path: NodePath = ^"Mesh"
@export var volume_mesh_path: NodePath = ^"VolumeMesh"
@export var world_seed := 12345
## Set by TimeController normally; tests drive ticks directly.
@export var listen_to_time_controller := true
## Bit flags passed to the kernel: 1 = no reactions, 2 = no decay (tests).
@export var rule_flags := 0
## Run the line-based liquid pressure solver after each tick.
@export var hydro_enabled := true
## Run the coarse air (velocity/pressure) solver once per simulation tick.
@export var air_enabled := true
## Rebuild the sun-visibility field whenever the world changes.
@export var sunvis_enabled := true
## Fill the sprite layers (grains, leaves, droplets) after each world change.
@export var sprites_enabled := true
## Advance the FX particle pool (embers, dust, splash) each frame.
@export var fx_enabled := true
## Opt-in coalescing: mutations stay ordered, but derived rendering is
## prepared once before viewport drawing or at an inspection barrier.
@export var defer_render_preparation := false:
	set(value):
		if defer_render_preparation == value:
			return
		defer_render_preparation = value
		if is_node_ready():
			RenderingServer.call_on_render_thread(_rt_set_deferred_preparation.bind(value))
## Capture pass timestamps (read with await profile_report()). Metal may not support them.
@export var profile := false
var volume_debug := 0
@export var jacobi_iterations := 20
@export var air_buoyancy := 0.03
@export var air_drag := 0.01
@export var air_max_speed := 1.5
## Preset world loaded at start and by R / Reload. `scenario=Name` on the
## command line (after `--`) overrides it.
@export var current_scenario := Scenarios.DEFAULT
## Sim seconds per tick, for FX particles and leaf sway; taken from
## TimeController when it drives the sim.
@export var seconds_per_tick := 1.0 / 120.0
## Temperature (K) of air on every whole-world replacement and the reference
## the air solver measures buoyancy against.
@export var ambient_temp := 293.15:
	set(value):
		ambient_temp = value
		if _rt_ready:
			RenderingServer.call_on_render_thread(_rt_update_initial_temps)
## Thermal seconds simulated per tick, as a multiple of the tick length:
## conduction at centimetre scale is far too slow to watch in real time.
@export var thermal_speed := 120.0
## Per-tick chance that a flammable cell at or above its ignition temperature catches.
@export var ignite_chance := 0.05
## Cost variants for the thermal layer (docs/milestone/thermal-physics.md,
## A/B'd by tools/milestone/thermal_bench.gd). All default to the plain
## behaviour.
## Skip conduction in blocks whose eight temperatures are identical (exact).
@export var thermal_block_early_out := false
## Skip thermal loads, conduction and phase change in all-air blocks (loses
## air-to-air conduction inside them; hot air still conducts where it meets material).
@export var thermal_skip_air_blocks := false
## Skip the hydro heat remap for runs whose amounts the pass leaves unchanged (exact).
@export var hydro_remap_skip_unchanged := false
## Read the thermal layer for buoyancy at every Nth voxel per axis (1 = all).
@export var air_heat_subsample := 1
## Run conduction, phase change and ignition every Nth tick with N times the
## thermal step (and N times the ignition chance), 1 = every tick.
@export var thermal_interval := 1

var tick := 0
## Absolute simulated tick used by presentation seeds, never rebuild count.
var _frame := 0
## Nonzero only while preparing presentation for elapsed simulation time.
var _rt_presentation_seconds := 0.0
## Render-thread-owned live source. Metadata updates never reset its phase.
var _rt_live_emitter: Dictionary = {}
var _rt_live_emitter_phase := 0.0
var _rt_live_emitter_initial := false
## Scheduled source stamps, not a count of cells accepted by ONLY_AIR.
var _rt_live_emitter_stamps := 0
const MAX_PENDING_LIVE_CLICKS := 32
const MAX_LIVE_CLICKS_PER_TICK := 4
var _rt_pending_live_clicks: Array[Dictionary] = []
var _rt_live_click_stamps := 0
## Cells or rays a moving live brush crossed between samples: each is stamped
## once inside the next tick so a fast drag lays a connected line. Bounded so a
## stalled frame cannot replay an unbounded backlog.
const MAX_LIVE_PATH_STAMPS := 512
var _rt_pending_live_path: Array[Dictionary] = []
var _rt_pending_live_surface: Array[Dictionary] = []
var _rt_live_surface_previous: Dictionary = {}
var _rt_live_path_stamps := 0
var _rt_defer_render_preparation := false
var _rt_derived_dirty := false
var _rt_preparing_render := false
var _rt_pending_presentation_seconds := 0.0
var _rt_pending_fx_ticks := 0
## Diagnostic: actual derived dispatch groups recorded, not GPU completion.
var _rt_render_preparation_count := 0
var _param_overrides := {}

var _rd: RenderingDevice
var _grid_rid := RID()
var _texture := Texture3DRD.new()
var _thermal_rid := RID()
## Bound to the thermal layer once the render thread has created it (see _process).
var thermal_texture := Texture3DRD.new()
var _thermal_init_shader := RID()
var _thermal_init_pipeline := RID()
var _thermal_init_set := RID()
var _thermal_init_buffer := RID()
var _material: ShaderMaterial
var _volume_material: ShaderMaterial
var _materials: Array = []
## Direction toward the sun, world space; set by the atmosphere each frame.
var sun_to := Vector3(0.4, 1.0, 0.3)
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
var _density_rid := RID()  # the RGBA8 "fields" texture (R liquid, G smoothed opaque, B gas)
var _density_texture := Texture3DRD.new()
var _physical_overflow_rid := RID() # one RGBA8 texel: whole-layer fallback flags
var _physical_overflow_texture := Texture3DRD.new()
var _density_shader := RID()
var _density_pipeline := RID()
var _density_set := RID()
var _fields_views: Array = []      # storage view per mip level
var _mip_shader := RID()
var _mip_pipeline := RID()
var _mip_sets: Array = []
var _occ_rid := RID()
var _occ_texture := Texture3DRD.new()
var _sunvis_rid := RID()
var _sunvis_texture := Texture3DRD.new()
var _sunvis_shader := RID()
var _sunvis_pipeline := RID()
var _sunvis_set := RID()
var _layer_multimesh: Array = []   # MultiMesh RIDs per Layer
var _layer_capacity: Array = []
var _layer_buffer: Array = []      # RD storage buffers behind each MultiMesh
var _splat_counter := RID()        # 32 uints: see splat_emit.glsl
var _splat_shader := RID()
var _splat_pipeline := RID()
var _splat_set := RID()
var _fx_shader := RID()
var _fx_pipeline := RID()
var _fx_set := RID()
var _fx_pool := RID()
var _fx_spawns := RID()
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
	var debug_mode := 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("scenario="):
			current_scenario = arg.substr(9)
		elif arg.begins_with("debug="):
			debug_mode = int(arg.substr(6))
		elif arg.begins_with("vdebug="):
			volume_debug = int(arg.substr(7))
		elif arg == "sunvis=0":
			sunvis_enabled = false
		elif arg == "sprites=0":
			sprites_enabled = false
		elif arg == "fx=0":
			fx_enabled = false
		elif arg == "defer=1":
			defer_render_preparation = true
		elif arg.begins_with("p:") and arg.contains("="):
			# p:name=value sets a float shader parameter on every material (tuning).
			var kv := arg.substr(2).split("=")
			_param_overrides[kv[0]] = float(kv[1])
	var mesh: MeshInstance3D = get_node(mesh_path)
	_material = mesh.material_override
	_volume_material = get_node(volume_mesh_path).material_override
	_materials = [_material, _volume_material]
	_layer_multimesh.resize(LAYER_COUNT)
	_layer_capacity.resize(LAYER_COUNT)
	_layer_buffer.resize(LAYER_COUNT)
	_layer_multimesh.fill(RID())
	_layer_capacity.fill(0)
	_layer_buffer.fill(RID())
	for child in get_children():
		if child is InstanceLayer:
			_layer_multimesh[child.role] = child.multimesh.get_rid()
			_layer_capacity[child.role] = child.capacity
			var sm: ShaderMaterial = child.material_override
			_materials.append(sm)
			sm.set_shader_parameter("box_center", Vector3.ZERO)
			sm.set_shader_parameter("box_half", 0.5 * world_size())
	if listen_to_time_controller:
		seconds_per_tick = 1.0 / TimeController.TICKS_PER_SECOND
	_material.set_shader_parameter("debug_mode", debug_mode)
	_volume_material.set_shader_parameter("volume_debug", volume_debug)
	set_param("grid_size", GRID)
	set_param("palette", Elements.palette())
	set_param("liquid_mask", Elements.liquid_mask())
	set_param("gas_mask", Elements.gas_mask())
	_volume_material.set_shader_parameter("extinction", MaterialLibrary.padded(Elements.extinction()))
	_volume_material.set_shader_parameter("liquid_foam", MaterialLibrary.padded(Elements.floats("foam", 1.0)))
	set_param("liquid_opacity", Elements.floats("opacity", 1.0))
	_volume_material.set_shader_parameter("liquid_full", float(Elements.LIQUID_FULL))
	set_param("fields", _density_texture)
	set_param("physical_overflow", _physical_overflow_texture)
	var powder_mask := 0
	var leafy_mask := 0
	for id in Elements.TABLE.size():
		if (Elements.TABLE[id].flags & Elements.FLAG_POWDER) != 0: powder_mask |= 1 << id
		if (Elements.TABLE[id].flags & Elements.FLAG_LEAFY) != 0: leafy_mask |= 1 << id
	_material.set_shader_parameter("powder_mask", powder_mask)
	_material.set_shader_parameter("leafy_mask", leafy_mask)
	set_param("sunvis", _sunvis_texture)
	MaterialLibrary.apply(_material)
	# Bound now, but only points at a real texture once the render thread has
	# created it (see _process). Re-bound every run because the RD texture
	# binding does not survive scene reloads.
	set_param("voxels", _texture)
	set_param("occupancy", _occ_texture)
	for k in _param_overrides:
		set_param(k, _param_overrides[k])
	set_param("brick_size", GRID / OCCUPANCY_GRID)
	RenderingServer.call_on_render_thread(_rt_init)
	# The first world is built on the GPU right after the textures exist.
	RenderingServer.call_on_render_thread(_rt_run_ops.bind(Scenarios.ops(current_scenario)))
	if listen_to_time_controller:
		TimeController.ticks_requested.connect(request_ticks)
	RenderingServer.frame_pre_draw.connect(_prepare_frame)


## Set a shader parameter on both raymarch materials.
func set_param(name: String, value: Variant) -> void:
	if name in MaterialLibrary.PER_ID_UNIFORMS:
		value = MaterialLibrary.padded(value)
	for m in _materials:
		m.set_shader_parameter(name, value)


## The sun-visibility texture, for other materials (ground shadow).
func sunvis_texture() -> Texture3DRD:
	return _sunvis_texture


## Render-thread RID of the thermal layer (valid after _rt_init).
func thermal_texture_rid() -> RID:
	return _thermal_rid


## Every texture that is authoritative cell state. Whole-world replacement,
## readback, regional history and cadence tests must cover all of them.
func authoritative_textures() -> Array[Dictionary]:
	return [
		{"name": "voxels", "rid": _grid_rid, "format": RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM, "bytes_per_cell": 4},
		{"name": "thermal", "rid": _thermal_rid, "format": THERMAL_FORMAT, "bytes_per_cell": THERMAL_BYTES_PER_CELL},
	]


func _exit_tree() -> void:
	if RenderingServer.frame_pre_draw.is_connected(_prepare_frame):
		RenderingServer.frame_pre_draw.disconnect(_prepare_frame)
	# Detach the material's view first, otherwise the renderer rebuilds its
	# uniform set against a freed texture at shutdown.
	_texture.texture_rd_rid = RID()
	thermal_texture.texture_rd_rid = RID()
	_occ_texture.texture_rd_rid = RID()
	_density_texture.texture_rd_rid = RID()
	_physical_overflow_texture.texture_rd_rid = RID()
	_sunvis_texture.texture_rd_rid = RID()
	RenderingServer.call_on_render_thread(_rt_free)


func _process(_delta: float) -> void:
	if _rt_ready and _texture.texture_rd_rid != _grid_rid:
		_texture.texture_rd_rid = _grid_rid
		thermal_texture.texture_rd_rid = _thermal_rid
		_occ_texture.texture_rd_rid = _occ_rid
		_density_texture.texture_rd_rid = _density_rid
		_physical_overflow_texture.texture_rd_rid = _physical_overflow_rid
		_sunvis_texture.texture_rd_rid = _sunvis_rid
	set_param("sim_time", tick * seconds_per_tick)


func _prepare_frame() -> void:
	# Godot emits frame_pre_draw on the main thread before queuing viewport
	# drawing. This queues our flush after edits/deferred callbacks but before
	# that draw, without relying on Node process priorities.
	if defer_render_preparation and _rt_ready:
		RenderingServer.call_on_render_thread(_rt_flush_render_preparation)


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

## Queue `count` fixed simulation ticks. Submission grouping does not change
## solver cadence. `tick` counts requested work, not completed GPU work.
func request_ticks(count: int) -> void:
	if count <= 0 or not _rt_ready:
		return
	RenderingServer.call_on_render_thread(_rt_tick.bind(tick, count))
	tick += count


## Submit any pending derived preparation. This is an ordering barrier, not
## a GPU completion fence; inspection readbacks flush automatically.
func flush_render_preparation() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_flush_render_preparation)


## Enable/update a source whose injection rate follows simulation time rather
## than rendered frames. First enable stamps before the next tick. Position
## updates preserve phase; a new seed denotes a new source session.
## Optional surface metadata is resolved on the GPU immediately before each
## stamp by the editing backend; missing surface support never falls back to
## a potentially stale center. No time advancement means no source emission.
func set_live_emitter(center: Vector3i, radius: int, element: int,
		mode: BrushMode = BrushMode.ONLY_AIR, rate: float = 24.0, seed: int = 1,
		surface: Dictionary = {}, shape: BrushShape = BrushShape.SPHERE, axis: int = 1) -> void:
	if not _rt_ready:
		return
	if element < 0 or element >= Elements.count() or not is_finite(rate) or rate <= 0.0:
		clear_live_emitter()
		return
	# A source update is user edit intent even before its next physical tick.
	# Async file loads must not overwrite a newer completed live gesture.
	edit_revision += 1
	var command := {
		"center": center.clamp(Vector3i.ZERO, Vector3i.ONE * (GRID - 1)),
		"radius": clampi(radius, 0, GRID), "element": element,
		"mode": mode, "rate": rate, "seed": seed & 0x7FFFFFFF,
		"surface": surface.duplicate(true), "shape": shape, "axis": clampi(axis, 0, 2),
	}
	RenderingServer.call_on_render_thread(_rt_set_live_emitter.bind(command))


func clear_live_emitter() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_clear_live_emitter)


## Intentional release: preserve a quick click if its first source tick has
## not happened yet. Each press/release is one immutable, tick-owned command.
## Cancel/navigation should use clear_live_emitter() instead.
func finish_live_emitter() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_finish_live_emitter)


## Workplane cells the live pointer crossed since its last sample. Each gets one
## stamp inside the next authoritative tick (ONLY_AIR or ERASE), independent of
## the held source's rate, so a drag leaves a connected line. Out-of-grid cells
## are dropped; the queue is bounded by MAX_LIVE_PATH_STAMPS.
func queue_live_path(centers: Array[Vector3i], radius: int, element: int,
		mode: BrushMode = BrushMode.ONLY_AIR, seed: int = 1,
		shape: BrushShape = BrushShape.SPHERE, axis: int = 1) -> void:
	if not _rt_ready or centers.is_empty() or element < 0 or element >= Elements.count():
		return
	if radius < 0 or radius > 12 or mode not in [BrushMode.ONLY_AIR, BrushMode.ERASE]:
		return
	var valid: Array[Vector3i] = []
	for center in centers:
		if center.x >= 0 and center.y >= 0 and center.z >= 0 and center.x < GRID and center.y < GRID and center.z < GRID:
			valid.append(center)
	if valid.is_empty():
		return
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_queue_live_path.bind({"centers": valid, "radius": radius,
		"element": element, "mode": mode, "seed": seed & 0x7FFFFFFF, "shape": shape, "axis": clampi(axis, 0, 2)}))


## Surface rays sampled by the live pointer. Consecutive connected rays are
## subdivided on the render thread so their GPU-picked stamps land on adjacent
## cells; each subdivided ray is picked and stamped atomically inside the tick.
func queue_live_surface_path(rays: Array, radius: int, element: int,
		mode: BrushMode = BrushMode.ONLY_AIR, seed: int = 1, shape: BrushShape = BrushShape.SPHERE) -> void:
	if not _rt_ready or element < 0 or element >= Elements.count() or radius < 0 or radius > 12:
		return
	if mode not in [BrushMode.ONLY_AIR, BrushMode.ERASE]:
		return
	var checked := _checked_rays(rays)
	if checked.is_empty():
		return
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_queue_live_surface_path.bind({"rays": checked, "radius": radius,
		"element": element, "mode": mode, "seed": seed & 0x7FFFFFFF, "shape": shape}))


## Paint a sphere of `element` (voxel units). Runs this frame, before any ticks
## queued after it, so painting works while time is frozen.
func paint(center: Vector3i, radius: int, element: int, mode: BrushMode = BrushMode.REPLACE,
		shape: BrushShape = BrushShape.SPHERE, axis: int = 1) -> void:
	if not _rt_ready:
		return
	edit_revision += 1
	var seed := randi() & 0x7FFFFFFF
	RenderingServer.call_on_render_thread(_rt_paint.bind(center, radius, element, mode, seed, shape, clampi(axis, 0, 2)))


## Discovery editor: preserve stamp order, rebuild derived fields once per batch.
func paint_stroke(centers: Array[Vector3i], radius: int, element: int, mode: BrushMode = BrushMode.ONLY_AIR,
		shape: BrushShape = BrushShape.SPHERE, axis: int = 1) -> void:
	if not _rt_ready or centers.is_empty():
		return
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_paint_stroke.bind(centers.duplicate(), radius, element, mode, randi() & 0x7FFFFFFF, shape, clampi(axis, 0, 2)))


## Half-open region bounds; construction fill preserves all occupied cells.
func paint_region(lo: Vector3i, hi: Vector3i, element: int) -> void:
	if _rt_ready:
		edit_revision += 1
		RenderingServer.call_on_render_thread(_rt_paint_region.bind(lo, hi, element))


## Capture only first-touched regions for this authored transaction. Mutations
## need not wait for the CPU readback; their GPU before-images are ordered first.
func begin_edit_transaction(callback: Callable) -> int:
	_edit_sequence += 1
	var id := _edit_sequence
	_edit_epochs[id] = edit_epoch
	RenderingServer.call_on_render_thread(_rt_begin_edit.bind(id, edit_epoch, callback))
	return id


func record_stroke(id: int, centers: Array[Vector3i], radius: int, element: int, mode: BrushMode = BrushMode.ONLY_AIR, seed: int = 1,
		shape: BrushShape = BrushShape.SPHERE, axis: int = 1) -> void:
	if _edit_epochs.get(id, -1) != edit_epoch:
		return
	if centers.is_empty() or element < 0 or element >= Elements.count() or radius < 0 or radius > 12:
		return
	var valid: Array[Vector3i] = []
	for center in centers:
		if VoxelCodec.in_bounds(center):
			valid.append(center)
	if valid.is_empty():
		return
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_record_stroke.bind(id, valid, radius, element, mode, seed, shape, clampi(axis, 0, 2)))


func record_region(id: int, lo: Vector3i, hi: Vector3i, element: int) -> void:
	if _edit_epochs.get(id, -1) != edit_epoch:
		return
	lo = lo.clamp(Vector3i.ZERO, Vector3i.ONE * GRID)
	hi = hi.clamp(Vector3i.ZERO, Vector3i.ONE * GRID)
	if lo.x >= hi.x or lo.y >= hi.y or lo.z >= hi.z or element < 0 or element >= Elements.count():
		return
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_record_region.bind(id, lo, hi, element))


func finish_edit_transaction(id: int) -> void:
	RenderingServer.call_on_render_thread(_rt_finish_edit.bind(id))


## Capture the current contents of aligned history tiles without painting:
## the same before-image path strokes use, closed as one record. Callers pass
## `{lo, hi}` tile bounds; the record is valid for restore_edit_transaction.
func capture_regions(bounds: Array, callback: Callable) -> int:
	var id := begin_edit_transaction(callback)
	RenderingServer.call_on_render_thread(_rt_capture_regions.bind(id, bounds))
	return id


## Preview is asynchronous and tagged; painting re-picks from its frozen ray.
func request_surface_pick(ray: Dictionary, radius: int, erase: bool, callback: Callable) -> void:
	request_surface_picks([ray], _deliver_surface_pick.bind(callback), radius, erase)


func _deliver_surface_pick(results: Array, callback: Callable) -> void:
	if callback.is_valid():
		callback.call(results[0])


## Batch preview pick (placement-brief contract 3): up to EditGPU.MAX_BATCH_RAYS
## rays resolve in one dispatch and one asynchronous download, so a frame's
## motion samples arrive together. `callback` receives an Array of pick
## dictionaries in ray order (invalid rays decode as misses), each tagged with
## `epoch`, `revision`, `tick` and `index`. The radius no longer moves an
## additive target; it is kept for API compatibility and bounds validation.
func request_surface_picks(rays: Array, callback: Callable, radius: int = 0, erase: bool = false) -> void:
	var metadata := {"epoch": edit_epoch, "revision": edit_revision, "tick": tick}
	var count := mini(rays.size(), EditGPU.MAX_BATCH_RAYS)
	var checked: Array = []
	var slots: Array = []
	for i in count:
		var value := _checked_surface(rays[i]) if rays[i] is Dictionary else {}
		if value.is_empty() or radius < 0 or radius > 12:
			slots.append(-1)
		else:
			slots.append(checked.size())
			checked.append(value)
	if checked.is_empty():
		_deliver_surface_picks([], slots, metadata, callback)
		return
	RenderingServer.call_on_render_thread(_rt_request_surface_picks.bind(checked, radius, erase, metadata, _deliver_surface_picks.bind(slots, metadata, callback)))


func _deliver_surface_picks(picked: Array, slots: Array, metadata: Dictionary, callback: Callable) -> void:
	var results: Array = []
	for i in slots.size():
		var slot: int = slots[i]
		var result: Dictionary
		if slot >= 0 and slot < picked.size():
			result = picked[slot]
		else:
			result = EditGPU.decode_pick(PackedByteArray())
			result.merge(metadata)
		result.index = i
		results.append(result)
	if callback.is_valid():
		callback.call_deferred(results)


func record_surface_stroke(id: int, rays: Array, radius: int, element: int, mode: BrushMode = BrushMode.ONLY_AIR, seed: int = 1,
		shape: BrushShape = BrushShape.SPHERE) -> void:
	if _edit_epochs.get(id, -1) != edit_epoch or radius < 0 or radius > 12 or element < 0 or element >= Elements.count() or mode not in [BrushMode.ONLY_AIR, BrushMode.ERASE]:
		return
	var checked := _checked_rays(rays)
	if not checked.is_empty():
		edit_revision += 1
		RenderingServer.call_on_render_thread(_rt_record_surface_stroke.bind(id, checked, radius, element, mode, seed, shape))


func paint_surface_stroke(rays: Array, radius: int, element: int, mode: BrushMode = BrushMode.ONLY_AIR, seed: int = 1,
		shape: BrushShape = BrushShape.SPHERE) -> void:
	if radius < 0 or radius > 12 or element < 0 or element >= Elements.count() or mode not in [BrushMode.ONLY_AIR, BrushMode.ERASE]:
		return
	var checked := _checked_rays(rays)
	if not checked.is_empty():
		edit_revision += 1
		RenderingServer.call_on_render_thread(_rt_paint_surface_stroke.bind(checked, radius, element, mode, seed, shape))


func _checked_surface(ray: Dictionary) -> Dictionary:
	var origin: Vector3 = ray.get("origin", Vector3.ZERO)
	var direction: Vector3 = ray.get("direction", Vector3.ZERO)
	if not origin.is_finite() or not direction.is_finite() or direction.length_squared() < 0.00000001:
		return {}
	return {"origin": origin, "direction": direction.normalized(), "section": bool(ray.get("section", false)),
		"axis": clampi(int(ray.get("axis", 2)), 0, 2), "depth": clampi(int(ray.get("depth", GRID - 1)), 0, GRID - 1),
		"mask": int(ray.get("mask", ((1 << Elements.count()) - 1) & ~Elements.gas_mask() & ~1)),
		"connect": bool(ray.get("connect", false))}


func _checked_rays(rays: Array) -> Array:
	var checked: Array = []
	for ray in rays:
		var value := _checked_surface(ray)
		if not value.is_empty():
			checked.append(value)
	return checked


func _rt_request_surface_picks(rays: Array, radius: int, erase: bool, metadata: Dictionary, callback: Callable) -> void:
	_rt_edit_gpu().request_picks(rays, radius, erase, metadata, callback)


func _rt_record_surface_stroke(id: int, rays: Array, radius: int, element: int, mode: int, seed: int, shape: int = BrushShape.SPHERE) -> void:
	var editor := _rt_edit_gpu()
	if not editor.transactions.has(id):
		return
	var tx: Dictionary = editor.transactions[id]
	var mutated := false
	# A frame's samples are picked together against the state they were aimed
	# at (one 64-byte fence per batch of 32 rays instead of one per ray); the
	# stamps are then applied in pointer order.
	var picks: Array = editor.pick_sync_batch(rays, radius, mode == BrushMode.ERASE)
	for i in rays.size():
		var ray: Dictionary = rays[i]
		if not ray.connect:
			tx.erase("surface_previous")
		var picked: Dictionary = picks[i]
		if not picked.valid:
			tx.erase("surface_previous")
			continue
		var centers: Array[Vector3i] = [picked.target]
		var normal: Vector3i = picked.normal
		var axis := normal.abs().max_axis_index()
		if tx.has("surface_previous"):
			centers = _surface_join(tx.surface_previous, picked)
		if not editor.capture_stroke(id, centers, radius):
			break
		var cl := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
		for center in centers:
			# A disc lies on the picked face plane, one cell thick along its normal.
			_rt_brush_sphere(cl, center, radius, element, mode, seed, Elements.default_amount(element), 0, shape, axis)
		_rd.compute_list_end()
		tx.surface_previous = picked
		mutated = true
	if mutated:
		_rt_occupancy_update()


## Join two consecutive surface targets. On the same face plane the join is the
## straight face-connected line. Across a corner (different normal) or a step
## (same normal, different plane) the line goes through the projection of the
## new target onto the previous face plane, so it follows the edge instead of
## cutting through space; ONLY_AIR keeps any solid it crosses intact.
static func _surface_join(previous: Dictionary, picked: Dictionary) -> Array[Vector3i]:
	var normal: Vector3i = picked.normal
	var from: Vector3i = previous.target
	var to: Vector3i = picked.target
	if normal == Vector3i.ZERO or previous.normal == Vector3i.ZERO:
		return [to]
	var axis: int = normal.abs().max_axis_index()
	if previous.normal == normal and from[axis] == to[axis]:
		return EditGeometry.stroke(from, to)
	var previous_axis: int = (previous.normal as Vector3i).abs().max_axis_index()
	var corner := to
	corner[previous_axis] = from[previous_axis]
	var centers := EditGeometry.stroke(from, corner)
	if corner != to:
		var second := EditGeometry.stroke(corner, to)
		second.remove_at(0)
		centers.append_array(second)
	return centers


func _rt_paint_surface_stroke(rays: Array, radius: int, element: int, mode: int, seed: int, shape: int = BrushShape.SPHERE) -> void:
	_rt_prepare_surface_emitter()
	var cl := _rd.compute_list_begin()
	for ray in rays:
		_rt_surface_emitter_stamp(cl, ray, radius, element, mode, seed, shape)
	_rd.compute_list_end()
	_rt_occupancy_update()


func _rt_prepare_surface_emitter() -> void:
	_rt_edit_gpu().ensure_surface()


## Called inside the simulator's authoritative tick list. No CPU pick is used.
func _rt_surface_emitter_stamp(cl: int, surface: Dictionary, radius: int, element: int, mode: int, seed: int, shape: int = BrushShape.SPHERE) -> void:
	var ray := _checked_surface(surface)
	if not ray.is_empty():
		_rt_edit_gpu().stamp_surface(cl, ray, radius, element, mode, seed, Elements.default_amount(element), shape)


## Capture and validate the inverse before changing GPU material. Failure
## leaves the source history usable; no full-volume readback is performed.
func reverse_edit_transaction(result: Dictionary, callback: Callable) -> bool:
	return _capture_history_state(result, callback, true)


## Used only when a new gesture might branch an existing redo chain. A true
## no-op must leave that future history intact.
func inspect_edit_transaction(result: Dictionary, callback: Callable) -> bool:
	return _capture_history_state(result, callback, false)


func _history_record_valid(result: Dictionary) -> bool:
	if not result.get("valid", false) or result.get("epoch", -1) != edit_epoch or not result.get("regions") is Array:
		return false
	var total := 0
	var seen := {}
	for region in result.regions:
		if not region is Dictionary or not region.get("lo") is Vector3i or not region.get("hi") is Vector3i or not region.get("bytes") is PackedByteArray:
			return false
		var lo: Vector3i = region.lo
		var hi: Vector3i = region.hi
		if not VoxelCodec.in_bounds(lo) or lo.x % EditGPU.TILE != 0 or lo.y % EditGPU.TILE != 0 or lo.z % EditGPU.TILE != 0:
			return false
		if hi != (lo + Vector3i.ONE * EditGPU.TILE).min(Vector3i.ONE * GRID) or seen.has(lo):
			return false
		seen[lo] = true
		var extent := hi - lo
		if region.bytes.size() != extent.x * extent.y * extent.z * EditGPU.BYTES_PER_CELL:
			return false
		total += region.bytes.size()
		if total > EditGPU.MAX_TRANSACTION_BYTES:
			return false
	return total > 0 and total == result.get("bytes", -1)


func _capture_history_state(result: Dictionary, callback: Callable, apply_restore: bool) -> bool:
	if not _rt_ready or not _history_record_valid(result):
		return false
	if apply_restore:
		edit_revision += 1 # Accepted user intent also invalidates pending file loads.
	var original := result.duplicate(true)
	var revision := edit_revision
	var at_tick := tick
	var id := begin_edit_transaction(func(captured: Dictionary):
		_complete_history_capture(captured, original, revision, at_tick, apply_restore, callback))
	RenderingServer.call_on_render_thread(_rt_capture_history_state.bind(id, original.regions))
	return true


func _rt_capture_history_state(id: int, regions: Array) -> void:
	_rt_edit_gpu().capture_existing_regions(id, regions)
	_rt_edit_gpu().finish(id)


func _complete_history_capture(captured: Dictionary, original: Dictionary, revision: int, at_tick: int, apply_restore: bool, callback: Callable) -> void:
	captured["applied"] = false
	captured["changed"] = false
	if not captured.get("valid", false) or captured.get("error", "") != "" or not _history_record_valid(captured) or captured.bytes != original.bytes or not _history_regions_match(captured.regions, original.regions):
		captured.valid = false
		captured.error = "History capture failed; no history action was applied."
	elif original.epoch != edit_epoch or edit_revision != revision or tick != at_tick:
		captured.valid = false
		captured.error = "The world changed during history capture; no history action was applied."
	else:
		for i in original.regions.size():
			if original.regions[i].bytes != captured.regions[i].bytes:
				captured.changed = true
				break
		if apply_restore:
			captured.applied = restore_edit_transaction(original)
			if not captured.applied:
				captured.valid = false
				captured.error = "This history belongs to a different world; no action was applied."
	callback.call(captured)


func _history_regions_match(captured: Array, original: Array) -> bool:
	if captured.size() != original.size():
		return false
	for i in original.size():
		if captured[i].lo != original[i].lo or captured[i].hi != original[i].hi:
			return false
	return true


func restore_edit_transaction(result: Dictionary) -> bool:
	if not result.get("valid", false) or result.get("epoch", -1) != edit_epoch or not result.has("regions"):
		return false
	for region in result.regions:
		var lo: Vector3i = region.lo
		var hi: Vector3i = region.hi
		var extent := hi - lo
		if not VoxelCodec.in_bounds(lo) or hi != hi.clamp(Vector3i.ZERO, Vector3i.ONE * GRID) or extent.x <= 0 or extent.y <= 0 or extent.z <= 0:
			return false
		if region.bytes.size() != extent.x * extent.y * extent.z * EditGPU.BYTES_PER_CELL:
			return false
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_restore_edit.bind(result.regions))
	return true


func _rt_edit_gpu() -> RefCounted:
	if _editor_gpu == null:
		_editor_gpu = EditGPU.new(_rd, _grid_rid, _thermal_rid, _elements_buffer, GRID, _rt_compile)
	return _editor_gpu


func _rt_begin_edit(id: int, epoch: int, callback: Callable) -> void:
	_rt_edit_gpu().begin(id, epoch, _on_edit_transaction.bind(callback))


func _on_edit_transaction(result: Dictionary, callback: Callable) -> void:
	_edit_epochs.erase(result.id)
	callback.call(result)
	edit_transaction_ready.emit(result)


func _rt_record_stroke(id: int, centers: Array[Vector3i], radius: int, element: int, mode: int, seed: int, shape: int = BrushShape.SPHERE, axis: int = 1) -> void:
	if _rt_edit_gpu().capture_stroke(id, centers, radius):
		_rt_paint_stroke(centers, radius, element, mode, seed, shape, axis)


func _rt_record_region(id: int, lo: Vector3i, hi: Vector3i, element: int) -> void:
	if _rt_edit_gpu().capture_region(id, lo, hi):
		_rt_paint_region(lo, hi, element)


func _rt_finish_edit(id: int) -> void:
	_rt_edit_gpu().finish(id)


func _rt_capture_regions(id: int, bounds: Array) -> void:
	var gpu := _rt_edit_gpu()
	for region in bounds:
		if not gpu.capture_region(id, region.lo, region.hi):
			break
	gpu.finish(id)


func _rt_restore_edit(regions: Array) -> void:
	_rt_edit_gpu().restore(regions)
	_rt_occupancy_update()


## Replace the whole world. `bytes` is GRID^3 * 4 bytes, x fastest. `thermal`
## is GRID^3 * 8 bytes (float32 temperature, float32 latent per cell) or empty,
## in which case every cell starts at its element's initial temperature.
func upload(bytes: PackedByteArray, thermal: PackedByteArray = PackedByteArray()) -> void:
	assert(bytes.size() == GRID * GRID * GRID * 4)
	assert(thermal.is_empty() or thermal.size() == GRID * GRID * GRID * THERMAL_BYTES_PER_CELL)
	edit_epoch += 1
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_upload.bind(bytes, thermal))
	tick = 0
	TimeController.reset_tick_counter()


func clear() -> void:
	edit_epoch += 1
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_clear)
	tick = 0
	TimeController.reset_tick_counter()


## Copy the world back to the CPU. `callback` receives the PackedByteArray on the
## main thread (next frame). Stalls the GPU; debug and tests only.
func request_readback(callback: Callable) -> void:
	RenderingServer.call_on_render_thread(_rt_readback.bind(callback))


## Copy the thermal layer back to the CPU; `thermal_ready` fires on the main
## thread with GRID^3 * 8 bytes. Stalls the GPU; inspection and tests only.
func request_thermal_readback() -> void:
	RenderingServer.call_on_render_thread(_rt_thermal_readback)


## Copy both authoritative layers back in one render-thread job so they come
## from the same tick; `state_ready(voxels, thermal)` fires on the main thread.
func request_state_readback() -> void:
	RenderingServer.call_on_render_thread(_rt_state_readback)


## Heat (positive kelvin) or cool (negative) a sphere in the thermal layer;
## voxel bytes are untouched. Falloff is radial, full strength at the centre.
func paint_thermal(center: Vector3i, radius: int, kelvin: float) -> void:
	paint_thermal_stroke([center], radius, kelvin)


func paint_thermal_stroke(centers: Array[Vector3i], radius: int, kelvin: float) -> void:
	if centers.is_empty() or radius < 0 or radius > 12 or not is_finite(kelvin):
		return
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_paint_thermal_stroke.bind(centers, radius, kelvin))


## Heat or cool the material under surface rays. Targets are resolved by the
## same atomic pick as material surface strokes (erase semantics: the hit
## cell itself, so the sphere is centred on the surface exactly like a
## workplane stamp and warms the air above as much as the material below;
## it is not pushed inward, which would overshoot thin walls), connected
## along a shared face like material strokes, and
## stamped with the brush kernel's HEAT/COOL sphere spaced by the radius
## (scripts/editor/thermal_stroke.gd), so surface and workplane strokes
## deposit the same heat. Undoable: history tiles carry the thermal layer.
func record_surface_thermal_stroke(id: int, rays: Array, radius: int, kelvin: float) -> void:
	if _edit_epochs.get(id, -1) != edit_epoch or radius < 0 or radius > 12 or not is_finite(kelvin):
		return
	var checked := _checked_rays(rays)
	if not checked.is_empty():
		edit_revision += 1
		RenderingServer.call_on_render_thread(_rt_record_surface_thermal_stroke.bind(id, checked, radius, kelvin))


## Live (Test) surface heating: immediate, not undoable, same targeting.
func paint_surface_thermal_stroke(rays: Array, radius: int, kelvin: float) -> void:
	if radius < 0 or radius > 12 or not is_finite(kelvin):
		return
	var checked := _checked_rays(rays)
	if not checked.is_empty():
		edit_revision += 1
		RenderingServer.call_on_render_thread(_rt_paint_surface_thermal_stroke.bind(checked, radius, kelvin))


var _live_surface_thermal := {}


## Resolve surface rays to spaced stamp centres. `state` keeps the previous
## pick and last stamp across calls of one stroke; a ray without `connect`
## starts a new segment.
func _rt_surface_thermal_centers(rays: Array, radius: int, state: Dictionary) -> Array[Vector3i]:
	var editor := _rt_edit_gpu()
	var out: Array[Vector3i] = []
	for ray in rays:
		if not ray.connect:
			state.erase("previous")
			state["last"] = Vector3i(-1, -1, -1)
		var picked: Dictionary = editor.pick_sync(ray, radius, true)
		if not picked.valid:
			state.erase("previous")
			continue
		var centers: Array[Vector3i] = [picked.target]
		if state.has("previous"):
			var previous: Dictionary = state.previous
			var normal: Vector3i = picked.normal
			var axis := normal.abs().max_axis_index()
			if normal != Vector3i.ZERO and previous.normal == normal and previous.target[axis] == picked.target[axis]:
				centers = EditGeometry.stroke(previous.target, picked.target)
		state.previous = picked
		var selected: Dictionary = ThermalStrokeSpacing.select(centers, radius, state.get("last", Vector3i(-1, -1, -1)))
		state["last"] = selected.last
		out.append_array(selected.centers)
	return out


func _rt_record_surface_thermal_stroke(id: int, rays: Array, radius: int, kelvin: float) -> void:
	var editor := _rt_edit_gpu()
	if not editor.transactions.has(id):
		return
	var tx: Dictionary = editor.transactions[id]
	if not tx.has("thermal_surface"):
		tx["thermal_surface"] = {}
	var centers := _rt_surface_thermal_centers(rays, radius, tx.thermal_surface)
	if not centers.is_empty() and editor.capture_stroke(id, centers, radius):
		_rt_paint_thermal_stroke(centers, radius, kelvin)


func _rt_paint_surface_thermal_stroke(rays: Array, radius: int, kelvin: float) -> void:
	var centers := _rt_surface_thermal_centers(rays, radius, _live_surface_thermal)
	if not centers.is_empty():
		_rt_paint_thermal_stroke(centers, radius, kelvin)


## Heat or cool as part of an undoable transaction (history records carry the
## thermal layer, so undo restores the previous temperatures exactly).
func record_thermal_stroke(id: int, centers: Array[Vector3i], radius: int, kelvin: float) -> void:
	if _edit_epochs.get(id, -1) != edit_epoch or centers.is_empty() or radius < 0 or radius > 12 or not is_finite(kelvin):
		return
	var valid: Array[Vector3i] = []
	for center in centers:
		if VoxelCodec.in_bounds(center):
			valid.append(center)
	if valid.is_empty():
		return
	edit_revision += 1
	RenderingServer.call_on_render_thread(_rt_record_thermal_stroke.bind(id, valid, radius, kelvin))


static func _float_bits(value: float) -> int:
	return PackedFloat32Array([value]).to_byte_array().decode_s32(0)


## One authoritative cell under a ray, for the hover inspector (heat-brief
## contract 4). `origin` and `direction` are in this node's model space (the
## unit box), as for request_surface_pick. `callback` receives {pos, element,
## temperature, amount, flags}; pos.x == -1 on a miss. Rides the surface pick
## record, never a full readback.
func request_cell_probe(origin: Vector3, direction: Vector3, callback: Callable) -> void:
	var mask := ((1 << Elements.count()) - 1) & ~1
	# A bound method, never a lambda: the callable can sit in a rendering
	# device frame until that frame is stalled, which may be process exit.
	request_surface_pick({"origin": origin, "direction": direction, "mask": mask}, 0, true, _deliver_probe.bind(callback))


func _deliver_probe(result: Dictionary, callback: Callable) -> void:
	if not callback.is_valid():
		return # the requester (an editor hovering every frame) may be gone by now
	if result.get("valid", false):
		callback.call({"pos": result.hit, "element": result.element, "temperature": result.temperature,
			"amount": result.amount, "flags": result.flags})
	else:
		callback.call({"pos": Vector3i(-1, -1, -1), "element": 0, "temperature": 0.0, "amount": 0, "flags": 0})


## Heat capacity of one cell in J/K: the element's capacity, scaled by
## amount / LIQUID_FULL whenever the amount byte is set (liquids always; ice,
## steam and smoke that carry the mass of the liquid they came from). A cell
## with no amount is a full cell. Keep in sync with cell_capacity in sim.glsl
## and hydro.glsl.
static func cell_capacity(id: int, amount: int) -> float:
	var c := Elements.thermal(id, "heat_capacity")
	if amount > 0:
		c *= float(amount) / float(Elements.LIQUID_FULL)
	return c


## Total thermal energy in joules over cells [lo, hi) of a world (the whole
## world by default): sum of cell_capacity * temperature + latent. CPU loop
## over every cell: tests at 128 only.
static func energy_total(voxels: PackedByteArray, thermal: PackedByteArray, lo := Vector3i.ZERO, hi := Vector3i(-1, -1, -1)) -> float:
	var n := VoxelCodec.GRID
	var cells := voxels.size() / 4
	assert(thermal.size() == cells * THERMAL_BYTES_PER_CELL)
	if hi.x < 0:
		hi = Vector3i(n, n, n)
	var capacity := PackedFloat64Array()
	capacity.resize(Elements.count())
	for id in Elements.count():
		capacity[id] = Elements.thermal(id, "heat_capacity")
	var values := thermal.to_float32_array()
	var total := 0.0
	for z in range(lo.z, hi.z):
		for y in range(lo.y, hi.y):
			for x in range(lo.x, hi.x):
				var i := VoxelCodec.index(x, y, z)
				var id := voxels[i * 4]
				var c := capacity[id]
				var amount := voxels[i * 4 + 2]
				if amount > 0:
					c *= float(amount) / float(Elements.LIQUID_FULL)
				total += c * values[i * 2] + values[i * 2 + 1]
	return total


## Fetch the 16^3 occupancy grid (one byte per brick, x fastest) without
## stalling; `occupancy_ready` fires on the main thread when it arrives.
func request_occupancy_readback() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_occupancy_readback)


## Sprite counts of the last emit (see Layer and fx.glsl); `layer_counts_ready`
## fires on the main thread with 32 ints. Stalls the GPU: tests only.
func request_layer_counts() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_layer_counts)


## The same counters fetched asynchronously (a frame or two late, no stall);
## `activity_ready` fires on the main thread. Used by the soundscape.
func request_activity() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_activity)


## Number of airborne-grain splats emitted last frame; `splat_count_ready`
## fires on the main thread. Stalls the GPU; tests only.
func request_splat_count() -> void:
	if _rt_ready:
		RenderingServer.call_on_render_thread(_rt_splat_count)


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
	_rt_defer_render_preparation = defer_render_preparation
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

	var thermal_fmt := RDTextureFormat.new()
	thermal_fmt.format = THERMAL_FORMAT
	thermal_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	thermal_fmt.width = GRID
	thermal_fmt.height = GRID
	thermal_fmt.depth = GRID
	thermal_fmt.mipmaps = 1
	thermal_fmt.usage_bits = fmt.usage_bits
	_thermal_rid = _rd.texture_create(thermal_fmt, RDTextureView.new())
	_rd.texture_clear(_thermal_rid, Color(ambient_temp, 0, 0, 0), 0, 1, 0, 1)
	var initial := initial_temperatures(ambient_temp).to_byte_array()
	_thermal_init_buffer = _rd.storage_buffer_create(initial.size(), initial)

	var props := Elements.property_bytes()
	_elements_buffer = _rd.storage_buffer_create(props.size(), props)
	var reacts := Elements.reaction_bytes()
	_reactions_buffer = _rd.storage_buffer_create(reacts.size(), reacts)

	var occ_fmt := RDTextureFormat.new()
	occ_fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM  # R solid, G fluid
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

	var sv_fmt := RDTextureFormat.new()
	sv_fmt.format = RenderingDevice.DATA_FORMAT_R8_UNORM
	sv_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	sv_fmt.width = GRID / SUNVIS_DIV
	sv_fmt.height = GRID / SUNVIS_DIV
	sv_fmt.depth = GRID / SUNVIS_DIV
	sv_fmt.mipmaps = 1
	sv_fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	_sunvis_rid = _rd.texture_create(sv_fmt, RDTextureView.new())
	_rd.texture_clear(_sunvis_rid, Color(1, 1, 1, 1), 0, 1, 0, 1)

	var zeros := PackedByteArray()
	zeros.resize(COUNTER_BYTES)
	_splat_counter = _rd.storage_buffer_create(COUNTER_BYTES, zeros)
	for i in LAYER_COUNT:
		if _layer_multimesh[i].is_valid():
			_layer_buffer[i] = RenderingServer.multimesh_get_buffer_rd_rid(_layer_multimesh[i])
	var spawn_zeros := PackedByteArray()
	spawn_zeros.resize(FX_SPAWN_CAPACITY * 32)
	_fx_spawns = _rd.storage_buffer_create(spawn_zeros.size(), spawn_zeros)
	if _layer_capacity[Layer.FX] > 0:
		var pool_zeros := PackedByteArray()
		pool_zeros.resize(_layer_capacity[Layer.FX] * 48)
		_fx_pool = _rd.storage_buffer_create(pool_zeros.size(), pool_zeros)

	var den_fmt := RDTextureFormat.new()
	den_fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	den_fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	den_fmt.width = GRID
	den_fmt.height = GRID
	den_fmt.depth = GRID
	den_fmt.mipmaps = FIELDS_MIPS
	den_fmt.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	)
	_density_rid = _rd.texture_create(den_fmt, RDTextureView.new())
	var overflow_fmt := RDTextureFormat.new()
	overflow_fmt.format = den_fmt.format
	overflow_fmt.texture_type = den_fmt.texture_type
	overflow_fmt.usage_bits = den_fmt.usage_bits
	overflow_fmt.width = 1
	overflow_fmt.height = 1
	overflow_fmt.depth = 1
	overflow_fmt.mipmaps = 1
	_physical_overflow_rid = _rd.texture_create(overflow_fmt, RDTextureView.new())
	_rd.texture_clear(_physical_overflow_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	# The froth channel (A) carries over between updates, so start it clean.
	_rd.texture_clear(_density_rid, Color(0, 0, 0, 0), 0, FIELDS_MIPS, 0, 1)
	_fields_views = []
	for m in FIELDS_MIPS:
		_fields_views.append(_rd.texture_create_shared_from_slice(
			RDTextureView.new(), _density_rid, 0, m, 1, RenderingDevice.TEXTURE_SLICE_3D))

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
	var thermal_init_spirv := _rt_compile(THERMAL_INIT_SHADER_PATH, from_source)
	var density_spirv := _rt_compile(FIELDS_SHADER_PATH, from_source)
	var mip_spirv := _rt_compile(FIELDS_MIP_SHADER_PATH, from_source)
	var sunvis_spirv := _rt_compile(SUNVIS_SHADER_PATH, from_source)
	var splat_spirv := _rt_compile(SPLAT_SHADER_PATH, from_source)
	var fx_spirv := _rt_compile(FX_SHADER_PATH, from_source)
	if sim_spirv == null or brush_spirv == null or occ_spirv == null or hydro_spirv == null \
			or density_spirv == null or mip_spirv == null or sunvis_spirv == null or splat_spirv == null \
			or fx_spirv == null or thermal_init_spirv == null:
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
		[_image_uniform(0), u_elems, u_reacts, _sampler_uniform(3, _air_vel[0]), _image_uniform(4, _thermal_rid)], _sim_shader, 0)

	_thermal_init_shader = _rd.shader_create_from_spirv(thermal_init_spirv)
	_thermal_init_pipeline = _rd.compute_pipeline_create(_thermal_init_shader, _spec([GRID]))
	_thermal_init_set = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _thermal_rid), _buffer_uniform(2, _thermal_init_buffer)], _thermal_init_shader, 0)

	# Air solver: downsample -> advect (vel0 -> vel1) -> divergence -> jacobi
	# (pres ping-pong, even count so the result lands in pres0) -> project (vel1 -> vel0).
	for k in AIR_KERNELS:
		_air_shaders[k] = _rd.shader_create_from_spirv(air_spirv[k])
		_air_pipelines[k] = _rd.compute_pipeline_create(_air_shaders[k], _spec([AIR_GRID, AIR_SUB]))
	_air_sets["air_downsample"] = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _air_occ), _image_uniform(2, _air_src), _buffer_uniform(3, _elements_buffer),
		_image_uniform(4, _thermal_rid)],
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
	_brush_set = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _thermal_rid), _buffer_uniform(2, _elements_buffer)], _brush_shader, 0)

	_hydro_shader = _rd.shader_create_from_spirv(hydro_spirv)
	_hydro_pipeline = _rd.compute_pipeline_create(_hydro_shader, _spec([GRID]))
	_hydro_set = _rd.uniform_set_create(
		[_image_uniform(0), _buffer_uniform(1, _elements_buffer), _image_uniform(2, _thermal_rid)], _hydro_shader, 0)

	_density_shader = _rd.shader_create_from_spirv(density_spirv)
	_density_pipeline = _rd.compute_pipeline_create(_density_shader, _spec([GRID]))
	# Custom scenes may omit physical layers. Their emission pipeline is disabled;
	# bind an existing buffer as an unused placeholder (cap.w prevents writes).
	var field_buffers: Array[RID] = []
	for i in 3:
		field_buffers.append(_layer_buffer[i] if _layer_buffer[i].is_valid() else _fx_spawns)
	_density_set = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _fields_views[0]), _buffer_uniform(2, _elements_buffer),
		_buffer_uniform(3, _splat_counter), _buffer_uniform(4, field_buffers[0]),
		_buffer_uniform(5, field_buffers[1]), _buffer_uniform(6, field_buffers[2]),
		_image_uniform(7, _physical_overflow_rid)], _density_shader, 0)
	_mip_shader = _rd.shader_create_from_spirv(mip_spirv)
	_mip_pipeline = _rd.compute_pipeline_create(_mip_shader)
	_mip_sets = []
	for m in range(1, FIELDS_MIPS):
		_mip_sets.append(_rd.uniform_set_create(
			[_image_uniform(0, _fields_views[m - 1]), _image_uniform(1, _fields_views[m])], _mip_shader, 0))

	_sunvis_shader = _rd.shader_create_from_spirv(sunvis_spirv)
	_sunvis_pipeline = _rd.compute_pipeline_create(_sunvis_shader, _spec([GRID / SUNVIS_DIV]))
	_sunvis_set = _rd.uniform_set_create(
		[_image_uniform(0, _sunvis_rid), _sampler_uniform(1, _density_rid)], _sunvis_shader, 0)

	var all_layers := true
	for i in LAYER_COUNT:
		if not _layer_buffer[i].is_valid():
			all_layers = false
	if all_layers:
		_splat_shader = _rd.shader_create_from_spirv(splat_spirv)
		_splat_pipeline = _rd.compute_pipeline_create(_splat_shader, _spec([GRID]))
		_splat_set = _rd.uniform_set_create(
			[_image_uniform(0), _image_uniform(1, _occ_rid), _buffer_uniform(2, _elements_buffer),
			_buffer_uniform(3, _splat_counter), _buffer_uniform(4, _layer_buffer[Layer.GRAINS]),
			_buffer_uniform(5, _layer_buffer[Layer.LEAVES]), _buffer_uniform(6, _layer_buffer[Layer.DROPLETS]),
			_buffer_uniform(7, _fx_spawns)], _splat_shader, 0)
		_fx_shader = _rd.shader_create_from_spirv(fx_spirv)
		_fx_pipeline = _rd.compute_pipeline_create(_fx_shader, _spec([GRID]))
		_fx_set = _rd.uniform_set_create(
			[_buffer_uniform(0, _fx_pool), _buffer_uniform(1, _fx_spawns), _buffer_uniform(2, _splat_counter),
			_buffer_uniform(3, _layer_buffer[Layer.FX]), _sampler_uniform(4, _air_vel[0]),
			_sampler_uniform(5, _density_rid)], _fx_shader, 0)

	_occ_shader = _rd.shader_create_from_spirv(occ_spirv)
	_occ_pipeline = _rd.compute_pipeline_create(_occ_shader)
	_occ_set = _rd.uniform_set_create(
		[_image_uniform(0), _image_uniform(1, _occ_rid), _buffer_uniform(2, _elements_buffer)], _occ_shader, 0)
	if from_source:
		print("compute shaders reloaded")


func _rt_free_pipelines() -> void:
	for ms in _mip_sets:
		if ms.is_valid():
			_rd.free_rid(ms)
	_mip_sets = []
	for rid in [_sim_set, _sim_pipeline, _sim_shader, _brush_set, _brush_pipeline, _brush_shader,
			_occ_set, _occ_pipeline, _occ_shader, _hydro_set, _hydro_pipeline, _hydro_shader,
			_density_set, _density_pipeline, _density_shader, _mip_pipeline, _mip_shader,
			_sunvis_set, _sunvis_pipeline, _sunvis_shader, _splat_set, _splat_pipeline, _splat_shader,
			_fx_set, _fx_pipeline, _fx_shader, _thermal_init_set, _thermal_init_pipeline, _thermal_init_shader]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_thermal_init_set = RID()
	_thermal_init_pipeline = RID()
	_thermal_init_shader = RID()
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
	_mip_pipeline = RID()
	_mip_shader = RID()
	_sunvis_set = RID()
	_sunvis_pipeline = RID()
	_sunvis_shader = RID()
	_splat_set = RID()
	_splat_pipeline = RID()
	_splat_shader = RID()
	_fx_set = RID()
	_fx_pipeline = RID()
	_fx_shader = RID()
	for d in [_air_sets, _air_pipelines, _air_shaders]:
		for k in d:
			if d[k].is_valid():
				_rd.free_rid(d[k])
		d.clear()


func _rt_free() -> void:
	if _editor_gpu != null:
		_editor_gpu.free_resources()
		_editor_gpu = null
	_rt_free_pipelines()
	for v in _fields_views:
		if v.is_valid():
			_rd.free_rid(v)
	_fields_views = []
	for rid in [_elements_buffer, _reactions_buffer, _grid_rid, _thermal_rid, _thermal_init_buffer, _occ_rid, _density_rid, _physical_overflow_rid, _sunvis_rid, _splat_counter,
			_fx_pool, _fx_spawns,
			_air_vel[0], _air_vel[1], _air_pres[0], _air_pres[1], _air_div, _air_occ, _air_src, _air_sampler]:
		if rid.is_valid():
			_rd.free_rid(rid)
	_elements_buffer = RID()
	_reactions_buffer = RID()
	_grid_rid = RID()
	_thermal_rid = RID()
	_thermal_init_buffer = RID()
	_occ_rid = RID()
	_density_rid = RID()
	_physical_overflow_rid = RID()
	_rt_ready = false


func _stamp(name: String) -> void:
	if profile:
		_rd.capture_timestamp("powder/" + name)


## Read the last captured frame on its owning render thread. This is asynchronous;
## callers must await it. Never interpret unavailable timestamps as zero GPU cost.
func profile_report() -> Dictionary:
	var replies: Array[Dictionary] = []
	RenderingServer.call_on_render_thread(_rt_profile_report.bind(func(value: Dictionary):
		replies.append(value)))
	while replies.is_empty():
		await get_tree().process_frame
	return replies[0]


func _rt_profile_report(callback: Callable) -> void:
	if not _rt_ready:
		callback.call_deferred({"available": false, "reason": "Simulation device is not ready"})
		return
	var markers: Array[Dictionary] = []
	var n := _rd.get_captured_timestamps_count()
	for i in n:
		markers.append({"name": _rd.get_captured_timestamp_name(i),
			"gpu_ns": _rd.get_captured_timestamp_gpu_time(i)})
	callback.call_deferred(GPUProfile.summarize(markers, _rd.get_captured_timestamps_frame()))


func _rt_tick(first_tick: int, count: int) -> void:
	if not _sim_pipeline.is_valid():
		return
	_stamp("frame_begin")
	var cl := _rd.compute_list_begin()
	var push := PackedInt32Array()
	push.resize(PUSH_CONSTANT_INTS)
	var hydro_groups := GRID / 8  # 8x8 threads per group, one line per thread
	for i in count:
		var t := first_tick + i
		_rt_live_emitter_step(cl)
		# Air samples and projects at a fixed simulation cadence. Advancing it
		# once with dt=count before a batch changes both the source sampling and
		# numerical integration when render frames group ticks differently.
		if air_enabled:
			_rt_air_step(cl, 1, t)
			_rd.compute_list_end()
			_stamp("air_tick")
			cl = _rd.compute_list_begin()
		var offset := partition_offset(t)
		push[0] = t
		push[1] = world_seed
		push[2] = 0 # reserved: never expose submission-local indices to physics
		push[3] = rule_flags | (0 if air_enabled else RULE_NO_AIR)
		push[4] = offset.x
		push[5] = offset.y
		push[6] = offset.z
		push[7] = Elements.REACTIONS.size()
		var interval := maxi(thermal_interval, 1)
		var thermal_tick := t % interval == 0
		push[3] = rule_flags | (0 if air_enabled else RULE_NO_AIR) | (0 if thermal_tick else RULE_NO_THERMAL)
		push[8] = _float_bits(seconds_per_tick * thermal_speed * interval)
		push[9] = _float_bits(ambient_temp)
		push[10] = _float_bits(minf(ignite_chance * interval, 1.0))
		push[11] = (1 if thermal_block_early_out else 0) | (2 if thermal_skip_air_blocks else 0)
		var bytes := push.to_byte_array()
		_rd.compute_list_bind_compute_pipeline(cl, _sim_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _sim_set, 0)
		_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
		_rd.compute_list_dispatch(cl, DISPATCH_GROUPS, DISPATCH_GROUPS, DISPATCH_GROUPS)
		_rd.compute_list_add_barrier(cl)
		if not hydro_enabled:
			continue
		_rd.compute_list_end()
		_stamp("sim_tick")
		cl = _rd.compute_list_begin()
		# Liquid pressure: exact columns, then relax rows along x or z alternately.
		_rd.compute_list_bind_compute_pipeline(cl, _hydro_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _hydro_set, 0)
		# Each mode runs as three dispatches: fold latent into energy, remap
		# heat along the run, then write amounts and temperatures. A single
		# dispatch could not read texels it had just written (hydro.glsl).
		for mode in [0, 1 + (t & 1)]:
			for stage in 3:
				var hp := PackedInt32Array([mode, t, world_seed, HYDRO_RELAX_PERCENT, stage, 1 if hydro_remap_skip_unchanged else 0, 0, 0]).to_byte_array()
				_rd.compute_list_set_push_constant(cl, hp, hp.size())
				_rd.compute_list_dispatch(cl, hydro_groups, hydro_groups, 1)
				_rd.compute_list_add_barrier(cl)
		_rd.compute_list_end()
		_stamp("hydro_tick")
		cl = _rd.compute_list_begin()
	_rd.compute_list_end()
	_frame = first_tick + count
	if _rt_defer_render_preparation:
		_rt_pending_presentation_seconds += count * seconds_per_tick
		_rt_pending_fx_ticks += count
		_rt_occupancy_update()
	else:
		_rt_presentation_seconds = count * seconds_per_tick
		_rt_occupancy_update()
		_rt_fx_step(count)
		_rt_presentation_seconds = 0.0
	_stamp("frame_end")


func _rt_set_live_emitter(command: Dictionary) -> void:
	# Surface resources must exist before the tick opens its compute list.
	var surface: Dictionary = command["surface"]
	if not surface.is_empty() and has_method("_rt_prepare_surface_emitter"):
		call("_rt_prepare_surface_emitter")
	var new_session: bool = _rt_live_emitter.is_empty() or _rt_live_emitter["seed"] != command["seed"]
	_rt_live_emitter = command
	if new_session:
		_rt_live_emitter_phase = 0.0
		_rt_live_emitter_initial = true
		_rt_live_emitter_stamps = 0


## Cancel: the held source and any crossed-but-unstamped path are dropped.
func _rt_clear_live_emitter(keep_path: bool = false) -> void:
	_rt_live_emitter = {}
	_rt_live_emitter_phase = 0.0
	_rt_live_emitter_initial = false
	_rt_live_surface_previous = {}
	if not keep_path:
		_rt_pending_live_path.clear()
		_rt_pending_live_surface.clear()


func _rt_finish_live_emitter() -> void:
	if not _rt_live_emitter.is_empty() and _rt_live_emitter_initial:
		if _rt_pending_live_clicks.size() < MAX_PENDING_LIVE_CLICKS:
			_rt_pending_live_clicks.append(_rt_live_emitter.duplicate(true))
		else:
			# Explicit overflow policy: preserve the first 32 intended clicks,
			# reject the newest; never replay an unbounded stalled-input backlog.
			push_warning("Live click queue full (32); newest click rejected until simulation advances")
	# An intentional release keeps the path the pointer already crossed.
	_rt_clear_live_emitter(true)


func _rt_queue_live_path(command: Dictionary) -> void:
	for center in command["centers"]:
		if _rt_pending_live_path.size() >= MAX_LIVE_PATH_STAMPS:
			push_warning("Live path queue full (%d); newest cells dropped until simulation advances" % MAX_LIVE_PATH_STAMPS)
			return
		_rt_pending_live_path.append({"center": center, "radius": command["radius"], "element": command["element"],
			"mode": command["mode"], "seed": command["seed"], "shape": command["shape"], "axis": command["axis"]})


func _rt_queue_live_surface_path(command: Dictionary) -> void:
	for ray in command["rays"]:
		if _rt_pending_live_surface.size() >= MAX_LIVE_PATH_STAMPS:
			push_warning("Live surface path queue full (%d); newest rays dropped until simulation advances" % MAX_LIVE_PATH_STAMPS)
			return
		_rt_pending_live_surface.append({"ray": ray, "radius": command["radius"], "element": command["element"],
			"mode": command["mode"], "seed": command["seed"], "shape": command["shape"]})


## Consecutive pointer rays are subdivided so their GPU-picked stamps land on
## adjacent cells. The hit point moves by about |delta direction| times the
## distance to the surface, bounded here by three model units (the camera never
## sits farther from the far corner of the unit cube in the editor).
func _rt_interpolate_rays(a: Dictionary, b: Dictionary) -> Array:
	var span: float = (b.direction - a.direction).length() * 3.0 * GRID + (b.origin - a.origin).length() * GRID
	var steps := clampi(ceili(span), 1, 64)
	var result: Array = []
	for i in range(1, steps + 1):
		var t := float(i) / steps
		var ray: Dictionary = b.duplicate(true)
		ray.origin = a.origin.lerp(b.origin, t)
		ray.direction = a.direction.lerp(b.direction, t).normalized()
		result.append(ray)
	return result


## Stamp the crossed path once per cell, before the held source's own stamp.
func _rt_live_path_step(cl: int) -> void:
	if not _rt_pending_live_path.is_empty():
		_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
		for stamp in _rt_pending_live_path:
			var seed := (int(stamp["seed"]) + _rt_live_path_stamps * 7919) & 0x7FFFFFFF
			_rt_brush_sphere(cl, stamp["center"], stamp["radius"], stamp["element"], stamp["mode"], seed, Elements.default_amount(stamp["element"]), 0, stamp["shape"], stamp["axis"])
			_rt_live_path_stamps += 1
		_rt_pending_live_path.clear()
	if _rt_pending_live_surface.is_empty():
		return
	if not has_method("_rt_surface_emitter_stamp"):
		_rt_pending_live_surface.clear()
		return
	call("_rt_prepare_surface_emitter")
	var stamps := 0
	for entry in _rt_pending_live_surface:
		var ray: Dictionary = entry["ray"]
		var steps: Array = [ray]
		if ray.get("connect", false) and not _rt_live_surface_previous.is_empty():
			steps = _rt_interpolate_rays(_rt_live_surface_previous, ray)
		for step in steps:
			if stamps >= MAX_LIVE_PATH_STAMPS:
				break
			var seed := (int(entry["seed"]) + _rt_live_path_stamps * 7919) & 0x7FFFFFFF
			call("_rt_surface_emitter_stamp", cl, step, entry["radius"], entry["element"], entry["mode"], seed, entry["shape"])
			_rt_live_path_stamps += 1
			stamps += 1
		_rt_live_surface_previous = ray
	_rt_pending_live_surface.clear()


## Record at most four queued clicks plus one held-source stamp in a tick.
## Sampling occurs
## before air and voxel transport, so ONLY_AIR sees the same preceding tick
## state regardless of how a renderer groups ticks into submissions.
func _rt_live_emitter_step(cl: int) -> void:
	for i in mini(MAX_LIVE_CLICKS_PER_TICK, _rt_pending_live_clicks.size()):
		var click: Dictionary = _rt_pending_live_clicks.pop_front()
		if _rt_emit_source(cl, click, 0):
			_rt_live_click_stamps += 1
	_rt_live_path_step(cl)
	# Older released clicks retain priority over a newer held source.
	if not _rt_pending_live_clicks.is_empty():
		return
	if _rt_live_emitter.is_empty():
		return
	if _rt_live_emitter_initial:
		_rt_live_emitter_initial = false
	else:
		# Bounded even if a caller requests an extreme rate: at most one stamp
		# per simulated tick, with no wall-clock backlog to replay after a stall.
		_rt_live_emitter_phase += minf(float(_rt_live_emitter["rate"]) * seconds_per_tick, 1.0)
		if _rt_live_emitter_phase < 1.0 - 1e-9:
			return
		_rt_live_emitter_phase = maxf(0.0, _rt_live_emitter_phase - 1.0)
	if _rt_emit_source(cl, _rt_live_emitter, _rt_live_emitter_stamps):
		_rt_live_emitter_stamps += 1


func _rt_emit_source(cl: int, command: Dictionary, ordinal: int) -> bool:
	var seed := (int(command["seed"]) + ordinal * 7919) & 0x7FFFFFFF
	var surface: Dictionary = command["surface"]
	if not surface.is_empty():
		if not has_method("_rt_surface_emitter_stamp"):
			return false
		# Editing owns the GPU pick+stamp implementation. It must add barriers
		# after the pick and mutation; air/sim rebind their pipelines afterward.
		call("_rt_surface_emitter_stamp", cl, surface, command["radius"], command["element"], command["mode"], seed, command.get("shape", BrushShape.SPHERE))
	else:
		_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
		_rt_brush_sphere(cl, command["center"], command["radius"], command["element"], command["mode"], seed, Elements.default_amount(command["element"]),
			0, command.get("shape", BrushShape.SPHERE), command.get("axis", 1))
	return true


## One air-solver step covering `dt` ticks, recorded into an open compute list.
func _rt_air_step(cl: int, dt: int, tick_now: int) -> void:
	if not _air_pipelines.has("air_project"):
		return
	var params := PackedFloat32Array([float(dt), air_buoyancy, air_drag, air_max_speed]).to_byte_array()
	params.append_array(PackedInt32Array([tick_now, _float_bits(ambient_temp), maxi(air_heat_subsample, 1), 0]).to_byte_array())
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
	_rt_flush_render_preparation()
	var bytes := _rd.texture_get_data(_air_vel[0], 0)
	velocity_ready.emit.call_deferred(bytes)


func _rt_air_clear() -> void:
	for rid in [_air_vel[0], _air_vel[1], _air_pres[0], _air_pres[1], _air_div, _air_occ, _air_src]:
		if rid.is_valid():
			_rd.texture_clear(rid, Color(0, 0, 0, 0), 0, 1, 0, 1)


## Clear solver and presentation history when replacing an authored world.
## Regional edits/undo deliberately do not call this: this is a fresh test
## state, not a full-runtime snapshot restore.
func _rt_reset_world_history() -> void:
	# A replacement discards the old experiment, including unpresented time.
	_rt_derived_dirty = false
	_rt_pending_presentation_seconds = 0.0
	_rt_pending_fx_ticks = 0
	_rt_clear_live_emitter()
	_rt_live_emitter_stamps = 0
	_rt_pending_live_clicks.clear()
	_rt_live_click_stamps = 0
	_rt_air_clear()
	_frame = 0
	_rt_presentation_seconds = 0.0
	_rd.texture_clear(_density_rid, Color(0, 0, 0, 0), 0, FIELDS_MIPS, 0, 1)
	_rd.texture_clear(_sunvis_rid, Color(1, 1, 1, 1), 0, 1, 0, 1)
	_rd.buffer_clear(_splat_counter, 0, COUNTER_BYTES)
	_rd.buffer_clear(_fx_spawns, 0, FX_SPAWN_CAPACITY * 32)
	if _fx_pool.is_valid():
		_rd.buffer_clear(_fx_pool, 0, _layer_capacity[Layer.FX] * 48)
	for layer in LAYER_COUNT:
		if _layer_buffer[layer].is_valid():
			_rd.buffer_clear(_layer_buffer[layer], 0, _layer_capacity[layer] * 64)


## Which of the 8 Margolus partitions to use on a given tick. Hashed rather
## than cycled so no direction is systematically favoured.
static func partition_offset(t: int) -> Vector3i:
	var h := (t * 2654435761) & 0xFFFFFFFF
	h ^= h >> 15
	h = (h * 2246822519) & 0xFFFFFFFF
	h ^= h >> 13
	return Vector3i(h & 1, (h >> 1) & 1, (h >> 2) & 1)


func _rt_paint(center: Vector3i, radius: int, element: int, mode: int, seed: int, shape: int = BrushShape.SPHERE, axis: int = 1) -> void:
	if not _brush_pipeline.is_valid():
		return
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
	_rt_brush_sphere(cl, center, radius, element, mode, seed, Elements.default_amount(element), 0, shape, axis)
	_rd.compute_list_end()
	_rt_occupancy_update()


func _rt_paint_stroke(centers: Array[Vector3i], radius: int, element: int, mode: int, seed: int, shape: int = BrushShape.SPHERE, axis: int = 1) -> void:
	if not _brush_pipeline.is_valid():
		return
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
	for center in centers:
		_rt_brush_sphere(cl, center, radius, element, mode, seed, Elements.default_amount(element), 0, shape, axis)
	_rd.compute_list_end()
	_rt_occupancy_update()


## One brush stamp: a sphere, cube or disc (BrushShape) of the given radius.
## The shape and disc axis ride in the box corner words the brush modes do
## not use; heat and cool always use the sphere with its falloff.
func _rt_brush_sphere(cl: int, center: Vector3i, radius: int, element: int, mode: int, seed: int, amount: int, strength_bits: int = 0,
		shape: int = BrushShape.SPHERE, axis: int = 1) -> void:
	var groups := ceili(float(2 * radius + 1) / BRUSH_LOCAL_SIZE)
	var push := PackedInt32Array([center.x, center.y, center.z, radius, element, mode, seed, amount, shape, axis, 0, strength_bits])
	var bytes := push.to_byte_array()
	_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
	_rd.compute_list_dispatch(cl, groups, groups, groups)
	_rd.compute_list_add_barrier(cl)


func _rt_brush_box(cl: int, lo: Vector3i, hi: Vector3i, element: int, seed: int, amount: int, mode: int = BrushMode.BOX) -> void:
	var size := (hi - lo).max(Vector3i.ZERO)
	if size.x == 0 or size.y == 0 or size.z == 0:
		return
	var push := PackedInt32Array([lo.x, lo.y, lo.z, 0, element, mode, seed, amount, hi.x, hi.y, hi.z, 0])
	var bytes := push.to_byte_array()
	_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
	_rd.compute_list_dispatch(cl, ceili(size.x / float(BRUSH_LOCAL_SIZE)), ceili(size.y / float(BRUSH_LOCAL_SIZE)), ceili(size.z / float(BRUSH_LOCAL_SIZE)))
	_rd.compute_list_add_barrier(cl)


func _rt_paint_thermal_stroke(centers: Array[Vector3i], radius: int, kelvin: float) -> void:
	if not _brush_pipeline.is_valid():
		return
	var mode := BrushMode.HEAT if kelvin >= 0.0 else BrushMode.COOL
	var strength := _float_bits(absf(kelvin))
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
	for center in centers:
		_rt_brush_sphere(cl, center, radius, 0, mode, 0, 0, strength)
	_rd.compute_list_end()


func _rt_record_thermal_stroke(id: int, centers: Array[Vector3i], radius: int, kelvin: float) -> void:
	if _rt_edit_gpu().capture_stroke(id, centers, radius):
		_rt_paint_thermal_stroke(centers, radius, kelvin)


func _rt_paint_region(lo: Vector3i, hi: Vector3i, element: int) -> void:
	if not _brush_pipeline.is_valid():
		return
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _brush_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _brush_set, 0)
	_rt_brush_box(cl, lo, hi, element, 7919, Elements.default_amount(element), BrushMode.BOX_ONLY_AIR)
	_rd.compute_list_end()
	_rt_occupancy_update()


## Clear the world and replay scenario ops (see Scenarios.ops) on the GPU.
func _rt_run_ops(ops: Array) -> void:
	if not _brush_pipeline.is_valid():
		return
	_rd.texture_clear(_grid_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_rt_reset_world_history()
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
	_rt_thermal_init()
	_rt_occupancy_update()


## Per-element initial temperatures (PALETTE_SIZE entries) for the thermal
## initialiser and painting: `Elements.thermal(id, "initial_temp")`, with air
## at the ambient temperature and unused ids at ambient too.
static func initial_temperatures(ambient: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(Elements.PALETTE_SIZE)
	out.fill(ambient)
	for id in Elements.count():
		out[id] = ambient if id == Elements.Id.AIR else Elements.thermal(id, "initial_temp")
	return out


func _rt_update_initial_temps() -> void:
	if _thermal_init_buffer.is_valid():
		var bytes := initial_temperatures(ambient_temp).to_byte_array()
		_rd.buffer_update(_thermal_init_buffer, 0, bytes.size(), bytes)


## Set every cell's temperature from its element (thermal_init.glsl). Only for
## whole-world replacements that carry no thermal bytes; never per tick.
func _rt_thermal_init() -> void:
	if not _thermal_init_pipeline.is_valid():
		return
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _thermal_init_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _thermal_init_set, 0)
	var push := PackedFloat32Array([ambient_temp, float(Elements.PALETTE_SIZE), 0.0, 0.0]).to_byte_array()
	_rd.compute_list_set_push_constant(cl, push, push.size())
	var groups := ceili(GRID / 8.0)
	_rd.compute_list_dispatch(cl, groups, groups, groups)
	_rd.compute_list_end()


func _rt_upload(bytes: PackedByteArray, thermal: PackedByteArray) -> void:
	_rd.texture_update(_grid_rid, 0, bytes)
	_rt_reset_world_history()
	if thermal.is_empty():
		_rt_thermal_init()
	else:
		_rd.texture_update(_thermal_rid, 0, thermal)
	_rt_occupancy_update()


func _rt_clear() -> void:
	_rd.texture_clear(_grid_rid, Color(0, 0, 0, 0), 0, 1, 0, 1)
	_rd.texture_clear(_thermal_rid, Color(ambient_temp, 0, 0, 0), 0, 1, 0, 1)
	_rt_reset_world_history()
	_rt_occupancy_update()


func _rt_set_deferred_preparation(enabled: bool) -> void:
	# Mode changes are ordered with simulation commands on the render thread.
	_rt_flush_render_preparation()
	_rt_defer_render_preparation = enabled


func _rt_flush_render_preparation() -> void:
	if not _rt_derived_dirty:
		return
	_rt_preparing_render = true
	_rt_derived_dirty = false
	_rt_presentation_seconds = _rt_pending_presentation_seconds
	_rt_occupancy_update()
	_rt_fx_step(_rt_pending_fx_ticks)
	_rt_presentation_seconds = 0.0
	_rt_pending_presentation_seconds = 0.0
	_rt_pending_fx_ticks = 0
	_rt_preparing_render = false


## Recompute everything derived from the voxel texture: the coarse occupancy
## grid and the liquid density field the renderer samples. Geometry-only
## refreshes use zero elapsed time and must not age foam or emit new FX.
func _rt_occupancy_update() -> void:
	if _rt_defer_render_preparation and not _rt_preparing_render:
		_rt_derived_dirty = true
		return
	if not _occ_pipeline.is_valid():
		return
	_rt_render_preparation_count += 1
	var groups := OCCUPANCY_GRID / 4
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _occ_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _occ_set, 0)
	_rd.compute_list_dispatch(cl, groups, groups, groups)
	_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()
	_stamp("occupancy")
	_rt_splat_emit()
	cl = _rd.compute_list_begin()
	if _density_pipeline.is_valid():
		var dg := GRID / 8
		_rd.compute_list_bind_compute_pipeline(cl, _density_pipeline)
		_rd.compute_list_bind_uniform_set(cl, _density_set, 0)
		var field_time := PackedInt32Array([_layer_capacity[Layer.GRAINS], _layer_capacity[Layer.LEAVES],
			_layer_capacity[Layer.DROPLETS], int(sprites_enabled and _splat_pipeline.is_valid())]).to_byte_array()
		field_time.append_array(PackedFloat32Array([_rt_presentation_seconds, 0.0, 0.0, 0.0]).to_byte_array())
		_rd.compute_list_set_push_constant(cl, field_time, field_time.size())
		_rd.compute_list_dispatch(cl, dg, dg, dg)
		_rd.compute_list_add_barrier(cl)
		_rd.compute_list_bind_compute_pipeline(cl, _mip_pipeline)
		for m in range(1, FIELDS_MIPS):
			var size := GRID >> m
			var push := PackedInt32Array([size, size, size, 0]).to_byte_array()
			_rd.compute_list_bind_uniform_set(cl, _mip_sets[m - 1], 0)
			_rd.compute_list_set_push_constant(cl, push, push.size())
			var mg := maxi(1, ceili(size / 4.0))
			_rd.compute_list_dispatch(cl, mg, mg, mg)
			_rd.compute_list_add_barrier(cl)
	_rd.compute_list_end()
	_stamp("fields_mips")
	cl = _rd.compute_list_begin()
	_rt_sunvis_sweep(cl)
	_rd.compute_list_end()
	_stamp("sunvis")


## Sweep the sun-visibility field along the sun's dominant axis, one dispatch
## per block of slabs (see sunvis.glsl).
func _rt_sunvis_sweep(cl: int) -> void:
	if not _sunvis_pipeline.is_valid() or not sunvis_enabled:
		return
	var d := sun_to.normalized()
	var axis := 0
	if absf(d.y) >= absf(d.x) and absf(d.y) >= absf(d.z):
		axis = 1
	elif absf(d.z) >= absf(d.x):
		axis = 2
	var sign_a := 1 if d[axis] >= 0.0 else -1
	var u_axis := 1 if axis == 0 else 0
	var v_axis := 2 if axis != 2 else 1
	var inv := 1.0 / maxf(absf(d[axis]), 1e-4)
	var step_u := d[u_axis] * inv
	var step_v := d[v_axis] * inv
	_rd.compute_list_bind_compute_pipeline(cl, _sunvis_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _sunvis_set, 0)
	var n := GRID / SUNVIS_DIV
	var groups := n / 16
	var k := 0
	while k < n:
		var push := PackedInt32Array([axis, sign_a, k, SUNVIS_SLABS_PER_DISPATCH]).to_byte_array()
		push.append_array(PackedFloat32Array([step_u, step_v, SUNVIS_GAS_EXTINCTION, 0.0]).to_byte_array())
		_rd.compute_list_set_push_constant(cl, push, push.size())
		_rd.compute_list_dispatch(cl, groups, groups, 1)
		_rd.compute_list_add_barrier(cl)
		k += SUNVIS_SLABS_PER_DISPATCH


## Refill the per-cell sprite layers (grains, leaves, droplets) and the FX
## spawn list from the current grid.
func _rt_splat_emit() -> void:
	if not _splat_pipeline.is_valid() or not sprites_enabled:
		return
	# Preserve the live-FX tally during paused edits; only FX integration
	# recomputes it. All geometric counters and spawn requests are refreshed.
	_rd.buffer_clear(_splat_counter, 0, 5 * 4)
	_rd.buffer_clear(_splat_counter, 6 * 4, COUNTER_BYTES - 6 * 4)
	for i in [Layer.GRAINS, Layer.LEAVES, Layer.DROPLETS]:
		_rd.buffer_clear(_layer_buffer[i], 0, _layer_capacity[i] * 64)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _splat_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _splat_set, 0)
	var push := PackedInt32Array([_layer_capacity[Layer.GRAINS], _layer_capacity[Layer.LEAVES],
		_layer_capacity[Layer.DROPLETS], FX_SPAWN_CAPACITY if _rt_presentation_seconds > 0.0 else 0, _frame, Elements.Id.STEAM, 0, 0]).to_byte_array()
	_rd.compute_list_set_push_constant(cl, push, push.size())
	var g := GRID / 8
	_rd.compute_list_dispatch(cl, g, g, g)
	_rd.compute_list_end()
	_stamp("sprites")


## Advance the FX particle pool by `ticks` of sim time: claim this frame's
## spawn requests, integrate, and rewrite the Fx layer's instances.
func _rt_fx_step(ticks: int) -> void:
	if not _fx_pipeline.is_valid() or ticks <= 0 or not fx_enabled:
		return
	var pool: int = _layer_capacity[Layer.FX]
	_rd.buffer_clear(_splat_counter, 5 * 4, 4)
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _fx_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _fx_set, 0)
	var push := PackedFloat32Array([ticks * seconds_per_tick, 1.0 / seconds_per_tick, float(FX_SPAWN_CAPACITY), 0.0]).to_byte_array()
	push.append_array(PackedInt32Array([pool, _frame, 0, 0]).to_byte_array())
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, ceili(pool / 64.0), 1, 1)
	_rd.compute_list_end()
	_stamp("fx")


func _rt_splat_count() -> void:
	_rt_flush_render_preparation()
	var bytes := _rd.buffer_get_data(_splat_counter, 0, 4)
	splat_count_ready.emit.call_deferred(bytes.decode_u32(0))


func _rt_layer_counts() -> void:
	_rt_flush_render_preparation()
	var bytes := _rd.buffer_get_data(_splat_counter, 0, COUNTER_BYTES)
	layer_counts_ready.emit.call_deferred(bytes.to_int32_array())


func _rt_activity() -> void:
	# Asynchronous sound telemetry samples the last prepared frame. It must
	# not defeat edit/tick coalescing by forcing an early geometry refresh.
	_rd.buffer_get_data_async(_splat_counter, _on_activity_bytes, 0, COUNTER_BYTES)


func _on_activity_bytes(bytes: PackedByteArray) -> void:
	activity_ready.emit.call_deferred(bytes.to_int32_array())


func _rt_density_readback() -> void:
	_rt_flush_render_preparation()
	_rd.texture_get_data_async(_density_rid, 0, _on_density_bytes)


func _on_density_bytes(bytes: PackedByteArray) -> void:
	density_ready.emit.call_deferred(bytes)


func _rt_occupancy_readback() -> void:
	_rt_flush_render_preparation()
	_rd.texture_get_data_async(_occ_rid, 0, _on_occupancy_bytes)


func _on_occupancy_bytes(bytes: PackedByteArray) -> void:
	occupancy_ready.emit.call_deferred(bytes)


func _rt_readback(callback: Callable) -> void:
	_rt_flush_render_preparation()
	var bytes := _rd.texture_get_data(_grid_rid, 0)
	callback.call_deferred(bytes)
	readback_ready.emit.call_deferred(bytes)


func _rt_thermal_readback() -> void:
	_rt_flush_render_preparation()
	thermal_ready.emit.call_deferred(_rd.texture_get_data(_thermal_rid, 0))


func _rt_state_readback() -> void:
	_rt_flush_render_preparation()
	var voxels := _rd.texture_get_data(_grid_rid, 0)
	var thermal := _rd.texture_get_data(_thermal_rid, 0)
	state_ready.emit.call_deferred(voxels, thermal)


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
	edit_epoch += 1
	edit_revision += 1
	current_scenario = name
	RenderingServer.call_on_render_thread(_rt_run_ops.bind(Scenarios.ops(name)))
	tick = 0
	TimeController.reset_tick_counter()
	scenario_changed.emit(name)
