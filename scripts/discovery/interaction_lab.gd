extends Node3D
## Runnable experiment using the production GPU state, brush kernel and renderer.
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
const FlyMotion := preload("res://scripts/camera/fly_motion.gd")
const FlyPreference := preload("res://scripts/editor/fly_preference.gd")
const SimScene := preload("res://scenes/sim_volume.tscn")
const Emission := preload("res://scripts/discovery/brush_emission.gd")
const HistoryBudget := preload("res://scripts/editor/history_budget.gd")
var document := preload("res://scripts/editor/authored_document.gd").new()
var document_guard: Node
const PendingGesture := preload("res://scripts/editor/pending_gesture.gd")
const PalettePanel := preload("res://scripts/editor/palette_panel.gd")
const KeepResult := preload("res://scripts/editor/keep_result.gd")
const CellInspector := preload("res://scripts/editor/cell_inspector.gd")
const ThermalStroke := preload("res://scripts/editor/thermal_stroke.gd")
var build_thermal := PackedByteArray()
var _state_waiters: Array[Callable] = []
## Kelvin added (Heat) or removed (Cool) per brush stamp.
var thermal_strength := 40.0
var _last_thermal_center := Vector3i(-1, -1, -1)
var probe_pending := false
var probe_text := ""
var ambient_input: SpinBox
var palette: RefCounted
var thermal_tool := "" # "", "heat" or "cool": the brush changes temperature, not material
const BrushScript := preload("res://scripts/sim/brush.gd")
## Brush shape (docs/milestone/placement-brief.md contract 5). Solids default to
## a cube and flowing materials to a sphere when the material changes, unless
## the user has picked a shape this session (Shape button or C).
var shape: int = BrushScript.Shape.SPHERE
var shape_overridden := false
var shape_button: Button
## Ghost preview (placement-brief contract 6): the exact cells the next stamp
## would change at the shown target, resolved on the GPU every frame. Above
## PREVIEW_MAX_CELLS only the bounding box is drawn (the marker).
const PREVIEW_MAX_CELLS := 4096
var preview_mesh: MultiMeshInstance3D
var _preview_cells: Array[Vector3i] = []
var preview_pending := false
var preview_request_id := 0
var preview_shown_id := -1
var preview_signature := 0
var preview_center := Vector3i(-1, -1, -1)
## Two-click tools (contract 7): "" paint, "line" or "box". The first click
## anchors, the second commits one authored transaction.
var tool_mode := ""
var tool_anchor := Vector3i(-1, -1, -1)
## Disc axis frozen at the anchor click, so a Line lies on the face the user
## started on even if the second pick lands on a differently facing surface.
var tool_anchor_axis := 1
var line_button: Button
var box_button: Button
var tool_box_mesh: MeshInstance3D
var stroke_thermal := ""
var speed_slider: HSlider
var speed_label: Label
var speed_scale := 1.0
var examples_choice: OptionButton
var _queued_example := ""
var keep_button: Button
var keeping := false
var pending_authored: RefCounted
var _capture_accepts_pending := false
enum TargetMode { PLANE, SURFACE }
var targeting_mode := TargetMode.PLANE
var target_choice: OptionButton
var section_toggle: CheckButton
var section_action: Button
var stroke_target_mode := TargetMode.PLANE
var pending_surface: Array = []
var surface_connect := false
var stroke_view := {}
var pick_pending := false
var pick_intent := 0
var pick_request_id := 0 # increases per issued preview pick
var pick_shown_id := -1  # id of the pick currently displayed
var pick_cache := {}
var tools_column: VBoxContainer
var archive_panel: Node
var _queued_editor_action := ""
var _queued_editor_epoch := -1
var _editor_action_scheduled := false
var _owns_time_input := false
var _previous_time_input := true
var live_emitter_signature := 0
var material_buttons := {}
var erase_button: Button
var advanced_tools: VBoxContainer
var advanced_toggle: CheckButton

var sim: Node3D
var camera: Camera3D
var axis := 2
var depth: int
var radius := 3
var element := Elements.Id.WATER
var erase := false
var section := true
var show_workplane_grid := true
var target := Vector3i(-1, -1, -1)
var painting := false
var previous := Vector3i(-1, -1, -1)
var pending: Array[Vector3i] = []
var status: Label
var depth_input: SpinBox
var marker: MeshInstance3D
var guide: MeshInstance3D
var orbiting := false
var yaw := 0.0
var pitch := 0.0
var distance := 1.25
var _ready_to_edit := false
var selecting := false
var corner_a := Vector3i(-1, -1, -1)
var corner_b := Vector3i(-1, -1, -1)
var selection_mesh: MeshInstance3D
var selection_status: Label
var selection_toggle: CheckButton
var capturing := false
var testing := false
var build_snapshot := PackedByteArray()
var undo_history: Array[Dictionary] = []
var undo_bytes := 0
var redo_history: Array[Dictionary] = []
var redo_bytes := 0
var undo_button: Button
var redo_button: Button
var active_transaction := -1
var last_edit_bytes := 0
var edit_message := ""
signal edit_completed(result: Dictionary)
var play_button: Button
var test_time_controls: HBoxContainer
var pause_button: Button
var step_button: Button
var stroke_radius := 3
var stroke_element := Elements.Id.WATER
var stroke_erase := false
var stroke_shape: int = BrushScript.Shape.SPHERE
var radius_input: SpinBox
var tools_panel: PanelContainer
## The scrolling part of the sidebar; the status footer sits below it, so this
## is not the panel's only child. Scroll a control into view through this.
var tools_scroll: ScrollContainer
var camera_target := Vector3.ZERO # box widths, independent of simulation size
## Optional WASD fly navigation (off by default); the orbit rig is unchanged
## and still owns looking around. See scripts/camera/fly_motion.gd.
var fly_enabled := false
var fly_toggle: CheckButton
var _fly_motion: RefCounted = null
var _base_fov := 75.0
var navigation_button := MOUSE_BUTTON_NONE
var navigation_pan := false
var depth_scroll_fraction := 0.0
var last_depth_scroll_ms := 0
const GESTURE_IDLE_MS := 350
var gesture_owner := -1 # -1: no sequence, 0: tools, 1: scene
var last_gesture_ms := -1
var gesture_trace := false
var _space_owned := false
## Every pointer motion event is a sample; above this many in one frame the
## stream is thinned evenly so a stalled frame cannot queue an unbounded backlog.
const MAX_SAMPLES_PER_FRAME := 64
var _frame_samples := 0
var _live_previous := Vector3i(-1, -1, -1)
var _live_surface_previous: Dictionary = {}
var _file_keys_owned := {}


func _ready() -> void:
	# The editor owns Build/Test transitions, including while a file chooser
	# temporarily suspends its own handlers. Legacy sandbox keys must not run
	# the authored world through an unhandled-input gap.
	_previous_time_input = TimeController.is_processing_unhandled_input()
	TimeController.set_process_unhandled_input(false)
	_owns_time_input = true
	gesture_trace = "gesture_trace=1" in OS.get_cmdline_user_args()
	if gesture_trace:
		print("GESTURE_TRACE ready: native pan/pinch events and routing will be logged")
	TimeController.paused = true
	depth = VoxelCodec.GRID / 2
	sim = SimScene.instantiate()
	sim.current_scenario = "Empty"
	add_child(sim)
	sim.set_process_unhandled_input(false)
	camera = Camera3D.new()
	camera.near = 0.001
	camera.fov = 58.0
	_base_fov = camera.fov
	_fly_motion = FlyMotion.new(sim.world_size())
	add_child(camera)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("18222e")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.8
	add_child(environment)
	preload("res://scripts/render/editor_presentation.gd").apply(sim, environment, self)
	# The marker is the stamp's bounding box; the preview multimesh draws the
	# exact cells inside it. Both are translucent overlays that ignore depth.
	marker = MeshInstance3D.new()
	marker.mesh = BoxMesh.new()
	marker.material_override = _overlay_material(Color(1.0, 0.78, 0.25, 0.10))
	add_child(marker)
	preview_mesh = MultiMeshInstance3D.new()
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = BoxMesh.new()
	preview_mesh.multimesh = multimesh
	preview_mesh.material_override = _overlay_material(Color(1.0, 0.78, 0.25, 0.38))
	add_child(preview_mesh)
	tool_box_mesh = MeshInstance3D.new()
	tool_box_mesh.mesh = BoxMesh.new()
	tool_box_mesh.material_override = _overlay_material(Color(0.5, 0.9, 1.0, 0.18))
	tool_box_mesh.visible = false
	add_child(tool_box_mesh)
	guide = MeshInstance3D.new()
	var guide_material := _overlay_material(Color(0.34, 0.75, 0.95, 0.10))
	guide_material.no_depth_test = false
	guide_material.render_priority = 0
	guide.material_override = guide_material
	add_child(guide)
	selection_mesh = MeshInstance3D.new()
	selection_mesh.mesh = BoxMesh.new()
	selection_mesh.material_override = _overlay_material(Color(0.6, 1.0, 0.5, 0.16))
	selection_mesh.visible = false
	add_child(selection_mesh)
	_build_ui()
	preload("res://scripts/editor/display_preferences.gd").mount(self, advanced_tools)
	preload("res://scripts/editor/editor_theme.gd").apply(tools_panel)
	archive_panel = preload("res://scripts/editor/archive_panel.gd").new()
	archive_panel.name = "AuthoredFiles"
	add_child(archive_panel)
	archive_panel.bind_editor(self, tools_column)
	document_guard = preload("res://scripts/editor/document_guard.gd").new()
	add_child(document_guard)
	document_guard.bind_editor(self)
	_face_plane()
	_update_plane()
	# Upload queues behind GPU initialization; no CPU state mirror is retained.
	reset_container()
	fly_enabled = FlyPreference.load_enabled()
	if fly_toggle:
		fly_toggle.set_pressed_no_signal(fly_enabled)
	_ready_to_edit = true


func _exit_tree() -> void:
	_release_shortcuts()
	cancel_pending_paint()
	if _owns_time_input and is_instance_valid(TimeController):
		TimeController.set_process_unhandled_input(_previous_time_input)
	_owns_time_input = false


## File payloads are validated by WorldArchive before reaching this boundary.
## Replacement starts a new authored world, never a partial runtime rewind.
func replace_authored(bytes: PackedByteArray, thermal: PackedByteArray = PackedByteArray()) -> bool:
	var cells := VoxelCodec.GRID * VoxelCodec.GRID * VoxelCodec.GRID
	if capturing or painting or bytes.size() != cells * 4 or not (thermal.is_empty() or thermal.size() == cells * 8):
		return false
	_end_stroke()
	_queued_editor_action = ""
	_invalidate_picks()
	_reset_gesture()
	_drop_tool_anchor() # the anchor named a cell in the world being replaced
	_stop_navigation()
	TimeController.paused = true
	testing = false
	_clear_history()
	last_edit_bytes = 0
	edit_message = ""
	build_snapshot.clear()
	build_thermal.clear()
	corner_a = Vector3i(-1, -1, -1)
	corner_b = Vector3i(-1, -1, -1)
	selecting = false
	selection_toggle.button_pressed = false
	selection_mesh.visible = false
	selection_status.text = "Region: no corners selected"
	play_button.text = "Run experiment · Space"
	sim.upload(bytes, thermal)
	document.reset()
	return true


## Every authoritative layer, read once and ordered on the render thread
## before any later edit. `callback(voxels, thermal)`; thermal is empty when
## the simulator has no thermal layer. Requests never share a completion.
func read_world(callback: Callable) -> void:
	if not sim.has_method("request_state_readback"):
		# Bound methods only: a lambda queued behind a device readback would
		# hold its script alive into display teardown at process exit.
		sim.request_readback(_receive_world_voxels.bind(callback))
		return
	# Both layers come from one render-thread job, so they are never paired
	# across ticks. Every reader takes exactly one completion, in request
	# order; a completion nobody is waiting for is dropped rather than queued,
	# so a foreign request_state_readback (a test, a tool) cannot leave a
	# stale layer for the next reader. The editor only reads while paused.
	if not sim.state_ready.is_connected(_on_state_ready):
		sim.state_ready.connect(_on_state_ready)
	_state_waiters.append(callback)
	sim.request_state_readback()


func _receive_world_voxels(bytes: PackedByteArray, callback: Callable) -> void:
	callback.call(bytes, PackedByteArray())


func _on_state_ready(voxels: PackedByteArray, thermal: PackedByteArray) -> void:
	if _state_waiters.is_empty():
		return
	var callback: Callable = _state_waiters.pop_front()
	if callback.is_valid():
		callback.call(voxels, thermal)


func _overlay_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	material.no_depth_test = true
	material.render_priority = 10
	return material


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	tools_panel = panel
	panel.position = Vector2(16, 16)
	layer.add_child(panel)
	var panel_column := VBoxContainer.new()
	panel_column.add_theme_constant_override("separation", 6)
	panel.add_child(panel_column)
	var scroll := ScrollContainer.new()
	tools_scroll = scroll
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_column.add_child(scroll)
	panel.size = Vector2(390, get_viewport().get_visible_rect().size.y - 32.0)
	get_viewport().size_changed.connect(func():
		panel.size.y = maxf(100.0, get_viewport().get_visible_rect().size.y - 32.0))
	var column := VBoxContainer.new()
	tools_column = column
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)
	var title := Label.new()
	title.text = "  PAINT & PLAY  "
	column.add_child(title)
	palette = PalettePanel.new()
	palette.build(self, column)
	var brush_row := HBoxContainer.new()
	column.add_child(brush_row)
	var radius_label := Label.new()
	radius_label.text = "r "
	radius_label.tooltip_text = "Brush radius in cells ([ and ])"
	brush_row.add_child(radius_label)
	radius_input = SpinBox.new()
	radius_input.min_value = 0
	radius_input.max_value = 12
	radius_input.value = radius
	radius_input.value_changed.connect(func(value):
		_end_stroke()
		radius = int(value))
	brush_row.add_child(radius_input)
	erase_button = Button.new()
	erase_button.text = "Erase"
	erase_button.tooltip_text = "Remove material instead of adding it (X)."
	erase_button.toggle_mode = true
	erase_button.pressed.connect(func():
		_end_stroke()
		thermal_tool = ""
		erase = not erase)
	brush_row.add_child(erase_button)
	shape_button = Button.new()
	shape_button.tooltip_text = "Brush shape: sphere, cube or disc (C). Solids default to cube, flowing materials to sphere."
	shape_button.pressed.connect(_cycle_shape)
	brush_row.add_child(shape_button)
	_refresh_shape_button()
	line_button = Button.new()
	line_button.text = "Line"
	line_button.toggle_mode = true
	line_button.tooltip_text = "Line (L): click a start cell, then an end cell, and the brush is stamped along a connected line between them."
	line_button.toggled.connect(func(enabled): _set_tool("line" if enabled else ""))
	brush_row.add_child(line_button)
	box_button = Button.new()
	box_button.text = "Box"
	box_button.toggle_mode = true
	box_button.tooltip_text = "Box (K): click two corners and the box between them fills with the current material where it is empty, or clears it when Erase is on."
	box_button.toggled.connect(func(enabled): _set_tool("box" if enabled else ""))
	brush_row.add_child(box_button)
	play_button = Button.new()
	play_button.text = "Run experiment · Space"
	play_button.tooltip_text = "Run the experiment. While it runs, a held still brush keeps pouring; drag to lay a line."
	play_button.pressed.connect(run_or_restore)
	column.add_child(play_button)
	var speed_row := HBoxContainer.new()
	column.add_child(speed_row)
	speed_label = Label.new()
	speed_label.text = "Speed 1×  "
	speed_label.custom_minimum_size.x = 90
	speed_row.add_child(speed_label)
	speed_slider = HSlider.new()
	speed_slider.min_value = -3
	speed_slider.max_value = 2
	speed_slider.step = 1
	speed_slider.value = 0
	speed_slider.tooltip_text = "Experiment speed, 1/8× to 4× real time"
	speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_slider.value_changed.connect(_set_speed_step)
	speed_row.add_child(speed_slider)
	TimeController.time_scale_changed.connect(_sync_speed)
	test_time_controls = HBoxContainer.new()
	test_time_controls.visible = false
	column.add_child(test_time_controls)
	pause_button = Button.new()
	pause_button.text = "Pause · P"
	pause_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pause_button.pressed.connect(toggle_test_pause)
	test_time_controls.add_child(pause_button)
	step_button = Button.new()
	step_button.text = "Single step · N"
	step_button.tooltip_text = "Pause and advance the experiment by one simulation tick"
	step_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	step_button.pressed.connect(step_test)
	test_time_controls.add_child(step_button)
	keep_button = Button.new()
	keep_button.text = "Keep result"
	keep_button.tooltip_text = "Make the current experiment state the build, as one undoable edit"
	keep_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	keep_button.pressed.connect(keep_result)
	test_time_controls.add_child(keep_button)
	var history_row := HBoxContainer.new()
	column.add_child(history_row)
	undo_button = Button.new()
	undo_button.text = "Undo build"
	undo_button.tooltip_text = "Undo · Ctrl/Cmd Z"
	undo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	undo_button.pressed.connect(undo_edit)
	history_row.add_child(undo_button)
	redo_button = Button.new()
	redo_button.text = "Redo build"
	redo_button.tooltip_text = "Redo · Ctrl/Cmd Shift Z"
	redo_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	redo_button.pressed.connect(redo_edit)
	history_row.add_child(redo_button)
	examples_choice = OptionButton.new()
	examples_choice.add_item("Examples…", 0)
	examples_choice.set_item_disabled(0, true)
	var example_index := 1
	for name in Scenarios.names():
		if name == "Empty":
			continue
		examples_choice.add_item(name, example_index)
		example_index += 1
	examples_choice.tooltip_text = "Load a ready-made build. Your unsaved work is protected first."
	examples_choice.item_selected.connect(func(index):
		var name := examples_choice.get_item_text(index)
		examples_choice.select(0)
		if index > 0:
			load_example(name))
	column.add_child(examples_choice)
	var target_row := HBoxContainer.new()
	column.add_child(target_row)
	var target_label := Label.new()
	target_label.text = "Paint on  "
	target_row.add_child(target_label)
	target_choice = OptionButton.new()
	target_choice.add_item("Workplane", TargetMode.PLANE)
	target_choice.add_item("Material surface", TargetMode.SURFACE)
	target_choice.item_selected.connect(_set_target_mode)
	target_choice.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_row.add_child(target_choice)
	section_toggle = CheckButton.new()
	section_toggle.text = "Cutaway"
	section_toggle.tooltip_text = "Hide cells beyond the selected plane to see inside. Material stays in the world."
	section_toggle.button_pressed = section
	section_toggle.toggled.connect(_set_section)
	target_row.add_child(section_toggle)
	section_action = Button.new()
	section_action.text = "Cutaway blocks paint here · Show whole world"
	section_action.tooltip_text = "This surface faces the hidden side. Show the whole world, then aim at its visible surface."
	section_action.visible = false
	section_action.pressed.connect(func(): _set_section(false))
	column.add_child(section_action)
	var planes := HBoxContainer.new()
	column.add_child(planes)
	for a in 3:
		var button := Button.new()
		button.text = ["X · side", "Y · top", "Z · front"][a]
		button.pressed.connect(func(): set_plane(a))
		planes.add_child(button)
	var row := HBoxContainer.new()
	column.add_child(row)
	var label := Label.new()
	label.text = "Plane cell  "
	row.add_child(label)
	depth_input = SpinBox.new()
	depth_input.min_value = 0
	depth_input.max_value = VoxelCodec.GRID - 1
	depth_input.value = depth
	depth_input.value_changed.connect(func(value):
		_end_stroke()
		if depth != int(value):
			_drop_tool_anchor()
		depth = int(value)
		_update_plane())
	row.add_child(depth_input)
	for step in [-1, 1]:
		var button := Button.new()
		button.text = "−" if step < 0 else "+"
		button.tooltip_text = "Move construction plane by one cell"
		button.pressed.connect(func():
			depth_scroll_fraction = 0.0
			depth_input.value += step)
		row.add_child(button)
	var navigation_row := HBoxContainer.new()
	column.add_child(navigation_row)
	for action in ["Zoom −", "Zoom +", "Center · V"]:
		var button := Button.new()
		button.text = action
		button.pressed.connect(func():
			_end_stroke()
			if action == "Center · V":
				_face_plane()
			else:
				_zoom(1.1 if action == "Zoom +" else 1.0 / 1.1))
		navigation_row.add_child(button)
	advanced_toggle = CheckButton.new()
	advanced_toggle.text = "Tools & view options"
	column.add_child(advanced_toggle)
	advanced_tools = VBoxContainer.new()
	advanced_tools.visible = false
	column.add_child(advanced_tools)
	advanced_toggle.toggled.connect(_set_advanced)
	selection_toggle = CheckButton.new()
	selection_toggle.text = "Select region · B (two corners)"
	selection_toggle.toggled.connect(func(enabled):
		cancel_pending_paint()
		_end_stroke()
		selecting = enabled
		if enabled:
			advanced_toggle.button_pressed = true
			if selection_mesh and corner_a.x >= 0 and corner_b.x >= 0:
				selection_mesh.show())
	advanced_tools.add_child(selection_toggle)
	selection_status = Label.new()
	selection_status.text = "Region: no corners selected"
	advanced_tools.add_child(selection_status)
	var fill := Button.new()
	fill.text = "Fill selected region into air"
	fill.pressed.connect(fill_selection)
	advanced_tools.add_child(fill)
	var grid_toggle := CheckButton.new()
	grid_toggle.text = "Show workplane grid"
	grid_toggle.button_pressed = show_workplane_grid
	grid_toggle.toggled.connect(func(enabled): show_workplane_grid = enabled)
	advanced_tools.add_child(grid_toggle)
	fly_toggle = CheckButton.new()
	fly_toggle.name = "FlyNavigation"
	fly_toggle.text = "Fly (WASD)"
	fly_toggle.tooltip_text = "Fly the camera: W A S D move, Q down, E up, Shift sprints. Two-finger drag, pinch and Option-drag keep looking around. Off by default; the orbit camera is unchanged."
	fly_toggle.button_pressed = fly_enabled
	fly_toggle.toggled.connect(set_fly_enabled)
	advanced_tools.add_child(fly_toggle)
	var ambient_row := HBoxContainer.new()
	advanced_tools.add_child(ambient_row)
	var ambient_label := Label.new()
	ambient_label.text = "Ambient °C  "
	ambient_row.add_child(ambient_label)
	ambient_input = SpinBox.new()
	ambient_input.min_value = -100
	ambient_input.max_value = 1000
	ambient_input.step = 1
	ambient_input.value = CellInspector.celsius(sim.ambient_temp) if "ambient_temp" in sim else 20
	ambient_input.tooltip_text = "Air temperature for new, reset, empty, example and older opened builds. Cells already placed keep their temperature."
	ambient_input.value_changed.connect(func(value):
		if "ambient_temp" in sim:
			sim.ambient_temp = value + CellInspector.ZERO_C)
	ambient_row.add_child(ambient_input)
	var reset := Button.new()
	reset.text = "Reset container…"
	reset.pressed.connect(reset_container)
	advanced_tools.add_child(reset)
	var empty := Button.new()
	empty.text = "Empty build…"
	empty.pressed.connect(func(): call("new_empty_build"))
	advanced_tools.add_child(empty)
	var controls := Label.new()
	controls.add_theme_font_size_override("font_size", 14)
	controls.text = "Drag: paint · two fingers: orbit · pinch: zoom\nShift + two fingers: pan · Option + drag: orbit"
	var secondary_controls := Label.new()
	secondary_controls.add_theme_font_size_override("font_size", 14)
	secondary_controls.text = "Option + Shift + drag: pan · RMB/wheel work too\nPlane: −/+ above · Shift-wheel · [ ] brush size\n1 sand · 2 water · 3 wall · X erase · F angle\nCmd/Ctrl: S save · Shift+S save as · O open"
	advanced_tools.add_child(secondary_controls)
	controls.tooltip_text = controls.text + "\n" + secondary_controls.text
	column.add_child(controls)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.x = 300
	# Pinned below the scrolling controls: what the next click will do must stay
	# on screen at laptop heights, whatever rows the current phase adds above.
	panel_column.add_child(status)
	get_tree().process_frame.connect(_refresh_palette)
	_refresh_palette()


func _add_material_button(parent: Container, id: int) -> void:
	var button := Button.new()
	button.text = Elements.TABLE[id].name
	button.toggle_mode = true
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var accent: Color = Elements.TABLE[id].color
	for state in ["normal", "hover", "pressed"]:
		var style := StyleBoxFlat.new()
		style.bg_color = Color("263442") if state == "normal" else Color("354958")
		style.border_color = accent.lightened(0.25)
		style.border_width_bottom = 4
		if state == "pressed":
			style.set_border_width_all(3)
		style.set_content_margin_all(8)
		style.set_corner_radius_all(4)
		button.add_theme_stylebox_override(state, style)
	button.pressed.connect(func(): _choose_material(id))
	material_buttons[id] = button
	parent.add_child(button)


func _choose_material(id: int) -> void:
	_end_stroke() # Commit using frozen stroke metadata before changing the tool.
	element = id
	erase = false
	thermal_tool = ""
	_apply_default_shape()
	_refresh_palette()


## Solids place as cubes, flowing materials as spheres, unless the user chose
## a shape this session.
func _apply_default_shape() -> void:
	if not shape_overridden:
		shape = BrushScript.default_shape(element)
	_refresh_shape_button()


func _cycle_shape() -> void:
	_end_stroke()
	shape = (shape + 1) % BrushScript.Shape.size()
	shape_overridden = true
	_refresh_shape_button()
	_refresh_palette()


static func shape_name(value: int) -> String:
	return ["Sphere", "Cube", "Disc"][clampi(value, 0, 2)]


func _refresh_shape_button() -> void:
	if shape_button:
		shape_button.text = shape_name(shape)


## Two-click tools. Switching tools or leaving tool mode drops the anchor;
## a queued or held paint stroke is ended first so no stroke spans the switch.
func _set_tool(mode: String) -> void:
	cancel_pending_paint()
	_end_stroke()
	tool_mode = mode
	_drop_tool_anchor()
	if line_button:
		line_button.set_pressed_no_signal(mode == "line")
	if box_button:
		box_button.set_pressed_no_signal(mode == "box")
	_refresh_palette()


func _toggle_tool(mode: String) -> void:
	_set_tool("" if tool_mode == mode else mode)


## An anchor belongs to one world, view and phase: it is dropped whenever the
## target space changes (targeting mode, plane axis or depth), history moves
## (undo, redo), the world is replaced (Open, Examples, Return), a gesture
## stream resets (focus loss), or the editor enters Test. Orbiting between the
## two clicks keeps it, since the target space is unchanged.
func _drop_tool_anchor() -> void:
	tool_anchor = Vector3i(-1, -1, -1)
	if tool_box_mesh:
		tool_box_mesh.visible = false


## Second click of a two-click tool: one authored transaction from the anchor
## to `cell`. Lines stamp the frozen brush along a face-connected path; boxes
## fill the axis-aligned box into air with the current material.
func _tool_click(cell: Vector3i) -> void:
	if cell.x < 0:
		return
	if testing:
		_drop_tool_anchor()
		edit_message = "Line and Box build the authored construction; return to Build to use them."
		return
	if tool_anchor.x < 0:
		tool_anchor = cell
		tool_anchor_axis = _preview_axis()
		return
	var anchor := tool_anchor
	var anchor_axis := tool_anchor_axis
	_drop_tool_anchor()
	if capturing:
		edit_message = "Previous edit still finishing; click again."
		tool_anchor = anchor
		return
	stroke_radius = radius
	stroke_element = element
	stroke_erase = erase
	stroke_shape = shape
	stroke_thermal = ""
	stroke_view = {"section": section, "axis": axis, "depth": depth}
	_begin_authored_edit()
	if tool_mode == "box":
		var lo := anchor.min(cell)
		var hi := anchor.max(cell) + Vector3i.ONE
		if stroke_erase:
			sim.record_region(active_transaction, lo, hi, Elements.Id.AIR, sim.BrushMode.BOX_ERASE)
		else:
			sim.record_region(active_transaction, lo, hi, element)
	else:
		sim.record_stroke(active_transaction, Geometry.stroke(anchor, cell), stroke_radius, stroke_element, _brush_mode(stroke_erase), active_transaction, stroke_shape, anchor_axis)
	_end_stroke()


## Axis a disc lies flat on for the shown target: the workplane axis, or the
## dominant axis of the picked face normal in surface mode.
func _preview_axis() -> int:
	if targeting_mode == TargetMode.SURFACE and pick_cache.get("valid", false):
		var normal: Vector3i = pick_cache.get("normal", Vector3i.ZERO)
		if normal != Vector3i.ZERO:
			return normal.abs().max_axis_index()
	return axis


## The cells the next stamp would change at the shown target, as last resolved
## by the GPU. Empty while no target is shown or a preview is still in flight.
func preview_cells() -> Array[Vector3i]:
	return _preview_cells


## Identity of the stamp the ghost must describe. `preview_signature` holds the
## signature of the cells currently displayed, so the ghost is up to date
## exactly when the two agree and nothing is in flight (`preview_current`).
func _preview_signature() -> int:
	return hash([target, radius, shape, erase, thermal_tool != "", _preview_axis(), sim.edit_revision, sim.edit_epoch])


## True when the displayed ghost describes the stamp the next click would make.
func preview_current() -> bool:
	return not preview_pending and target.x >= 0 and preview_signature == _preview_signature()


func _request_stamp_preview() -> void:
	if preview_pending or not sim.has_method("request_stamp_preview"):
		return
	var signature := _preview_signature()
	if signature == preview_signature:
		return
	preview_pending = true
	preview_request_id += 1
	# Heat and cool always stamp the sphere (brush.glsl forces it for those modes).
	var preview_shape: int = BrushScript.Shape.SPHERE if thermal_tool != "" else shape
	sim.request_stamp_preview(target, radius, erase, preview_shape, _preview_axis(), _receive_stamp_preview.bind(preview_request_id, signature), thermal_tool != "")


func _receive_stamp_preview(cells: Array[Vector3i], metadata: Dictionary, id: int, signature: int) -> void:
	preview_pending = false
	if id <= preview_shown_id or metadata.get("epoch", -1) != sim.edit_epoch:
		return
	preview_shown_id = id
	preview_signature = signature
	_preview_cells = cells
	_rebuild_preview_mesh()


func _rebuild_preview_mesh() -> void:
	if preview_mesh == null:
		return
	var multimesh := preview_mesh.multimesh
	var count := _preview_cells.size()
	if count == 0 or count > PREVIEW_MAX_CELLS:
		multimesh.instance_count = 0
		return
	var cell_size: float = sim.world_size() / VoxelCodec.GRID
	multimesh.instance_count = count
	for i in count:
		var origin: Vector3 = ((Vector3(_preview_cells[i]) + Vector3.ONE * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5) * sim.world_size()
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * cell_size * 0.98), origin))


func _clear_stamp_preview() -> void:
	_preview_cells = []
	preview_signature = 0
	if preview_mesh and preview_mesh.multimesh:
		preview_mesh.multimesh.instance_count = 0


func _choose_thermal(tool: String) -> void:
	_end_stroke()
	if not PalettePanel.thermal_brushes_available(sim):
		return
	thermal_tool = "" if thermal_tool == tool else tool
	erase = false
	_refresh_palette()


## Material brush mode for frozen stroke metadata. Thermal strokes never use
## it: they go through record_thermal_stroke / paint_thermal_stroke.
func _brush_mode(erase_flag: bool) -> int:
	return sim.BrushMode.ERASE if erase_flag else sim.BrushMode.ONLY_AIR


## Plane axis of the frozen stroke view: a disc lies flat on that workplane.
func _stroke_axis() -> int:
	return int(stroke_view.get("axis", axis)) if stroke_view is Dictionary else axis


func _thermal_kelvin(tool: String) -> float:
	return thermal_strength if tool == "heat" else -thermal_strength


func _set_speed_step(step: float) -> void:
	speed_scale = pow(2.0, step)
	speed_label.text = "Speed %s×  " % ("1/%d" % int(round(1.0 / speed_scale)) if speed_scale < 1.0 else str(int(speed_scale)))
	if testing and not TimeController.is_frozen():
		TimeController.time_scale = speed_scale
	elif testing and TimeController.paused:
		TimeController.time_scale = speed_scale


func _sync_speed(target_scale: float) -> void:
	if not testing or speed_slider == null or target_scale < TimeController.MIN_SCALE:
		return
	var step := clampf(round(log(target_scale) / log(2.0)), speed_slider.min_value, speed_slider.max_value)
	if pow(2.0, step) != speed_scale:
		speed_scale = pow(2.0, step)
		speed_slider.set_value_no_signal(step)
		speed_label.text = "Speed %s×  " % ("1/%d" % int(round(1.0 / speed_scale)) if speed_scale < 1.0 else str(int(speed_scale)))


func toggle_test_pause() -> void:
	if not testing or capturing:
		return
	_end_stroke()
	TimeController.toggle_pause()
	_refresh_test_controls()


func step_test() -> void:
	if not testing or capturing:
		return
	_end_stroke()
	TimeController.step()
	_refresh_test_controls()


func _test_phase() -> String:
	if not testing:
		return "BUILD"
	return "TEST · PAUSED" if TimeController.is_frozen() else "TEST · RUNNING"


func _refresh_test_controls() -> void:
	if test_time_controls:
		test_time_controls.visible = testing
		pause_button.text = "Resume · P" if TimeController.is_frozen() else "Pause · P"
		pause_button.disabled = capturing
		step_button.disabled = capturing


func _refresh_palette() -> void:
	_refresh_test_controls()
	_refresh_target_controls()
	if undo_button:
		undo_button.disabled = testing or (undo_history.is_empty() and not capturing)
		redo_button.disabled = testing or (redo_history.is_empty() and not capturing)
	for id in material_buttons:
		material_buttons[id].set_pressed_no_signal(id == element and not erase and thermal_tool == "")
	if erase_button:
		erase_button.set_pressed_no_signal(erase)
	if palette:
		palette.refresh(self)
	if keep_button:
		keep_button.disabled = capturing or keeping


func _set_advanced(enabled: bool) -> void:
	advanced_tools.visible = enabled
	if enabled and selection_mesh and corner_a.x >= 0 and corner_b.x >= 0:
		selection_mesh.show()
	if not enabled:
		_end_stroke()
		selecting = false
		selection_toggle.set_pressed_no_signal(false)
		if selection_mesh:
			selection_mesh.hide()


func reset_container() -> void:
	if _wait_for_edit("reset"):
		return
	if _ready_to_edit and is_instance_valid(document_guard):
		document_guard.request("reset", _reset_container_now)
	else:
		_reset_container_now()


func _reset_container_now() -> void:
	var n := VoxelCodec.GRID
	var data := WorldBuilder.empty()
	WorldBuilder.fill_bowl(data, Vector3i(n / 4, n / 6, n / 4), Vector3i(n * 3 / 4, n * 2 / 3, n * 3 / 4), maxi(2, n / 64))
	WorldBuilder.fill_box(data, Vector3i(n / 3, n / 5, n / 3), Vector3i(n * 2 / 3, n / 3, n * 2 / 3), Elements.Id.WATER)
	replace_authored(data.to_byte_array())


func new_empty_build() -> void:
	if not _wait_for_edit("empty"):
		if is_instance_valid(document_guard):
			document_guard.request("empty", func(): replace_authored(WorldBuilder.empty().to_byte_array()))
		else:
			replace_authored(WorldBuilder.empty().to_byte_array())


## Examples replace the construction like Open: a fresh authored world behind
## the unsaved-build guard, not a runtime rewind and not part of Build history.
func load_example(name: String) -> void:
	if name.is_empty() or name not in Scenarios.names():
		return
	_queued_example = name
	if _wait_for_edit("example"):
		return
	var apply := func(): replace_authored(Scenarios.build(name))
	if _ready_to_edit and is_instance_valid(document_guard):
		document_guard.request("example", apply)
	else:
		apply.call()


## Keep the live experiment as the authored build. The changed history tiles
## become one regional transaction: Undo returns to the previous build, Redo
## re-applies the kept result. Larger changes fall back to a new authored
## build, reported as such, rather than silently exceeding the history budget.
func keep_result() -> void:
	if not testing or keeping:
		return
	if _wait_for_edit("keep"):
		return
	keeping = true
	capturing = true
	_capture_accepts_pending = false
	edit_message = "Keeping the experiment result…"
	TimeController.paused = true
	_refresh_test_controls()
	read_world(_keep_diff.bind(sim.edit_epoch))


func _keep_diff(live: PackedByteArray, live_thermal: PackedByteArray, epoch: int) -> void:
	if not testing or sim.edit_epoch != epoch or live.size() != build_snapshot.size() or live_thermal.size() != build_thermal.size():
		_keep_finish("The experiment changed while keeping; nothing was kept.")
		return
	var tile: int = sim.EditGPU.TILE
	var tiles := KeepResult.changed_tiles_all({"voxels": build_snapshot, "thermal": build_thermal}, {"voxels": live, "thermal": live_thermal}, VoxelCodec.GRID, tile)
	if tiles.is_empty():
		_keep_finish("Nothing changed; the build is already this result.")
		return
	var bounds := KeepResult.bounds(tiles, VoxelCodec.GRID, tile)
	if KeepResult.byte_count(tiles, VoxelCodec.GRID, tile, sim.EditGPU.BYTES_PER_CELL) > sim.EditGPU.MAX_TRANSACTION_BYTES:
		# Too much changed for one undoable edit: keep it as a new unsaved build.
		testing = false
		play_button.text = "Run experiment · Space"
		if not WorldArchive._thermal_finite(live_thermal):
			live_thermal = PackedByteArray() # fall back to element defaults rather than upload NaN
		replace_authored(live, live_thermal)
		document.changed({})
		_keep_finish("Kept as a new build: too much changed to undo in one step.")
		return
	# Capture the live tiles first, in the history layout, before returning.
	sim.capture_regions(bounds, func(live_record: Dictionary): _keep_captured_live(live_record, bounds, epoch))


func _keep_captured_live(live_record: Dictionary, bounds: Array, epoch: int) -> void:
	if not testing or sim.edit_epoch != epoch or not live_record.valid or live_record.regions.is_empty():
		_keep_finish("Could not capture the experiment result; nothing was kept.")
		return
	# Return to the authored revision exactly as Return does, then record the
	# kept tiles as one edit on top of it.
	sim.upload(build_snapshot, build_thermal)
	for transaction in undo_history + redo_history:
		transaction.epoch = sim.edit_epoch
	testing = false
	play_button.text = "Run experiment · Space"
	var new_epoch: int = sim.edit_epoch
	# The before-image buffer captures the authored tiles ahead of the queued
	# restore; both are ordered on the render thread behind the upload.
	sim.capture_regions(bounds, func(before: Dictionary): _keep_record(before, new_epoch))
	sim.restore_edit_transaction({"valid": true, "epoch": new_epoch, "regions": live_record.regions, "bytes": live_record.bytes})


func _keep_record(before: Dictionary, epoch: int) -> void:
	if not before.valid or before.regions.is_empty() or before.epoch != epoch or sim.edit_epoch != epoch:
		_clear_history()
		document.changed({})
		_keep_finish("Kept the result, but its Undo could not be recorded; history was cleared.")
		return
	document.changed(before)
	redo_history.clear()
	redo_bytes = 0
	undo_history.append(before)
	undo_bytes += before.bytes
	_trim_history()
	last_edit_bytes = before.bytes
	_keep_finish("Kept the experiment result as the build.")
	edit_completed.emit(before)


func _keep_finish(message: String) -> void:
	keeping = false
	capturing = false
	edit_message = message
	_refresh_palette()


## Preserve the latest explicit action while the finished stroke's regional
## history is arriving. This is a single intent, never an unbounded click queue.
func _wait_for_edit(action: String) -> bool:
	cancel_pending_paint()
	_end_stroke()
	if not capturing:
		_queued_editor_action = ""
		return false
	_queued_editor_action = action
	_queued_editor_epoch = sim.edit_epoch
	_schedule_editor_action()
	edit_message = "Finishing edit…"
	return true


func _schedule_editor_action() -> void:
	if not _editor_action_scheduled:
		_editor_action_scheduled = true
		get_tree().process_frame.connect(_resume_editor_action, CONNECT_ONE_SHOT)


func _resume_editor_action() -> void:
	_editor_action_scheduled = false
	if _queued_editor_action.is_empty():
		return
	if capturing:
		_schedule_editor_action()
		return
	var action := _queued_editor_action
	_queued_editor_action = ""
	if _queued_editor_epoch != sim.edit_epoch:
		if edit_message == "Finishing edit…":
			edit_message = ""
		return
	match action:
		"undo": undo_edit()
		"redo": redo_edit()
		"start_test": _set_testing(true)
		"return_build": _set_testing(false)
		"reset": reset_container()
		"empty": new_empty_build()
		"example": load_example(_queued_example)
		"keep": keep_result()


func _set_target_mode(value: int) -> void:
	cancel_pending_paint()
	_end_stroke()
	_drop_tool_anchor()
	targeting_mode = value
	target_choice.select(value)
	_invalidate_picks()
	_refresh_target_controls()


func _set_section(enabled: bool) -> void:
	_end_stroke()
	section = enabled
	section_toggle.set_pressed_no_signal(enabled)
	_update_plane()
	_refresh_target_controls()


func _surface_block_reason() -> String:
	if pick_cache.is_empty() or pick_cache.get("valid", false):
		return ""
	var hit: Vector3i = pick_cache.get("hit", Vector3i(-1, -1, -1))
	if not VoxelCodec.in_bounds(hit):
		return "miss"
	var cell: Vector3i = pick_cache.get("target", Vector3i(-1, -1, -1))
	if not VoxelCodec.in_bounds(cell):
		return "boundary"
	if section and cell[axis] > depth:
		return "section"
	if pick_cache.get("normal", Vector3i.ZERO) == Vector3i.ZERO:
		return "inside"
	return "unavailable"


func _surface_feedback() -> String:
	if pick_cache.is_empty():
		return "Finding surface…" if pick_pending else "Aim at a visible material surface"
	match _surface_block_reason():
		"section": return "Cutaway blocks adding here · Show whole world above"
		"boundary": return "Target leaves the world · use a smaller brush or another face"
		"inside": return "View starts inside material · orbit to an outside face"
		"miss": return "No surface here · aim at visible material"
		"unavailable": return "Surface target unavailable · aim at another face"
	return "Surface: erase hit material" if erase else "Surface: add outside visible material"


func _refresh_target_controls() -> void:
	if section_action:
		section_action.visible = targeting_mode == TargetMode.SURFACE and _surface_block_reason() == "section"
	if section_toggle:
		section_toggle.set_pressed_no_signal(section)


func set_plane(value: int) -> void:
	_end_stroke()
	_drop_tool_anchor()
	axis = value
	_face_plane()
	_update_plane()


func _face_plane() -> void:
	camera_target = Vector3.ZERO
	distance = 1.25
	yaw = PI / 2.0 if axis == 0 else 0.0
	pitch = -PI / 2.0 + 0.001 if axis == 1 else 0.0
	_update_camera()


func _update_camera() -> void:
	cancel_pending_paint()
	_invalidate_picks()
	var direction := Vector3(sin(yaw) * cos(pitch), -sin(pitch), cos(yaw) * cos(pitch))
	camera.position = (camera_target + direction * distance) * sim.world_size()
	camera.look_at(camera_target * sim.world_size(), Vector3.UP)


func _zoom(factor: float) -> void:
	if not is_finite(factor) or factor <= 0.0:
		return
	distance = clampf(distance / factor, 0.7, 4.0)
	_update_camera()


func _navigate(delta: Vector2, pan: bool, gesture: bool = false) -> void:
	if not delta.is_finite():
		return
	if pan:
		var amount := distance * (0.035 if gesture else 0.0015)
		camera_target += (-camera.global_basis.x * delta.x + camera.global_basis.y * delta.y) * amount
		camera_target = camera_target.clamp(Vector3.ONE * -1.5, Vector3.ONE * 1.5)
	else:
		var sensitivity := 0.035 if gesture else 0.005
		yaw = wrapf(yaw - delta.x * sensitivity, -PI, PI)
		pitch = clampf(pitch - delta.y * sensitivity, -1.56, 1.56)
	_update_camera()


func _over_tools(position: Vector2) -> bool:
	return tools_panel != null and tools_panel.get_global_rect().has_point(position)


func _stop_navigation() -> void:
	orbiting = false
	navigation_button = MOUSE_BUTTON_NONE
	navigation_pan = false


## Gesture-stream bookkeeping only. This runs on every mouse press, so it must
## not disturb a two-click tool: the anchor is dropped where the world, the
## target space or the phase changes, not where a gesture starts.
func _reset_gesture() -> void:
	gesture_owner = -1
	last_gesture_ms = -1


func _route_gesture(event: InputEventGesture) -> void:
	cancel_pending_paint()
	# Godot's native gesture events carry no begin/end phase. Keep the initial
	# owner across a stream, releasing after an idle gap or explicit input/focus
	# boundary. Route scene gestures before GUI dispatch can swallow an update.
	var now := Time.get_ticks_msec()
	if last_gesture_ms < 0 or now - last_gesture_ms > GESTURE_IDLE_MS:
		gesture_owner = 0 if _over_tools(event.position) else 1
	last_gesture_ms = now
	_end_stroke()
	_stop_navigation()
	depth_scroll_fraction = 0.0
	if gesture_owner == 1:
		if event is InputEventPanGesture:
			_navigate(event.delta, event.shift_pressed, true)
		elif event is InputEventMagnifyGesture:
			_zoom(event.factor)
		get_viewport().set_input_as_handled()
	elif not _over_tools(event.position):
		# A toolbar scroll moving into the scene must not become navigation.
		get_viewport().set_input_as_handled()
	if gesture_trace:
		print("GESTURE_TRACE ", JSON.stringify({"ms": now, "type": event.get_class(),
			"position": str(event.position), "owner": "scene" if gesture_owner == 1 else "tools",
			"over_tools": _over_tools(event.position), "shift": event.shift_pressed,
			"amount": event.factor if event is InputEventMagnifyGesture else str(event.delta),
			"distance": distance, "target": str(camera_target)}))


func _wheel_depth(amount: float) -> void:
	var now := Time.get_ticks_msec()
	if now - last_depth_scroll_ms > 350:
		depth_scroll_fraction = 0.0
	last_depth_scroll_ms = now
	depth_scroll_fraction += amount
	var steps := int(depth_scroll_fraction)
	if steps != 0:
		depth_input.value += steps
		depth_scroll_fraction -= steps
	if depth_input.value == depth_input.min_value or depth_input.value == depth_input.max_value:
		depth_scroll_fraction = 0.0


func _update_plane() -> void:
	cancel_pending_paint()
	_invalidate_picks()
	sim.set_param("section_enabled", section)
	sim.set_param("section_axis", axis)
	sim.set_param("section_cell", depth)
	if guide == null:
		return # the workplane state is set; there is no guide to redraw yet
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var u := (axis + 1) % 3
	var v := (axis + 2) % 3
	var n := VoxelCodec.GRID
	# Coarse guide every eight cells, exact cell shown by cursor and coordinates.
	for i in range(0, n + 1, maxi(1, n / 16)):
		for swap in 2:
			for end in 2:
				var p := Vector3.ZERO
				p[axis] = float(depth) + 0.5
				p[u if swap == 0 else v] = i
				p[v if swap == 0 else u] = n * end
				mesh.surface_add_vertex((p / n - Vector3.ONE * 0.5) * sim.world_size())
	mesh.surface_end()
	guide.mesh = mesh


func _route_space(event: InputEventKey) -> bool:
	if event.keycode != KEY_SPACE:
		return false
	if not event.pressed:
		if not _space_owned:
			return false
		_space_owned = false
		get_viewport().set_input_as_handled()
		return true
	if event.echo:
		if _space_owned:
			get_viewport().set_input_as_handled()
		return _space_owned
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return false
	if event.alt_pressed or event.ctrl_pressed or event.meta_pressed:
		return false
	if event.window_id != get_window().get_window_id():
		return false
	if is_instance_valid(archive_panel) and archive_panel._modal:
		return false
	if focused is OptionButton and focused.get_popup().visible:
		return false
	# Claim both edges before GUI dispatch: a focused Button otherwise also
	# activates on Space release after the editor starts Run on the press.
	_space_owned = true
	depth_scroll_fraction = 0.0
	get_viewport().set_input_as_handled()
	run_or_restore()
	return true


func _release_shortcuts() -> void:
	_space_owned = false
	_file_keys_owned.clear()
	if _fly_motion != null:
		# A movement key released while another window had focus is never seen
		# here; stop rather than coast on a request that no longer exists.
		_fly_motion.stop()


## Layouts without Latin letters report another keycode for the S key; the
## physical key is the fallback only then. A different Latin letter on that
## physical position (Colemak R, Dvorak R, QWERTZ Y) is that letter, as in
## Godot's own editor shortcuts.
func _shortcut_key(event: InputEventKey, accepted: Array) -> int:
	if event.keycode in accepted:
		return event.keycode
	if event.keycode >= KEY_A and event.keycode <= KEY_Z:
		return KEY_NONE
	return event.physical_keycode if event.physical_keycode in accepted else KEY_NONE


func _route_file_shortcut(event: InputEventKey) -> bool:
	var code := _shortcut_key(event, [KEY_S, KEY_O])
	if code == KEY_NONE or event.window_id != get_window().get_window_id():
		return false
	if not event.pressed:
		if not _file_keys_owned.has(code):
			return false
		_file_keys_owned.erase(code)
		get_viewport().set_input_as_handled()
		return true
	if event.echo:
		if _file_keys_owned.has(code):
			get_viewport().set_input_as_handled()
		return _file_keys_owned.has(code)
	if not (event.ctrl_pressed or event.meta_pressed) or event.alt_pressed or (code == KEY_O and event.shift_pressed):
		return false
	if not is_instance_valid(archive_panel) or archive_panel._modal:
		return false
	var focused := get_viewport().gui_get_focus_owner()
	if focused is OptionButton and focused.get_popup().visible:
		return false
	# File commands are application shortcuts, including from numeric text.
	# Undo/Redo and cut/copy/paste continue through the focused text control.
	_file_keys_owned[code] = true
	get_viewport().set_input_as_handled()
	if code == KEY_S:
		archive_panel.request_save(event.shift_pressed)
	else:
		archive_panel._queue_dialog("open")
	return true


func _input(event: InputEvent) -> void:
	if event is InputEventKey and (_route_file_shortcut(event) or _route_space(event)):
		return
	if event is InputEventPanGesture or event is InputEventMagnifyGesture:
		_route_gesture(event)
		return
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		_reset_gesture()
		depth_scroll_fraction = 0.0
	if event is InputEventKey and event.pressed and event.keycode != KEY_SHIFT:
		depth_scroll_fraction = 0.0
	if event is InputEventKey and not event.pressed and event.keycode == KEY_SHIFT:
		depth_scroll_fraction = 0.0
	# Releases must terminate even over UI or after leaving the viewport.
	if event is InputEventMouseButton and not event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_end_stroke(true)
		if event.button_index == navigation_button:
			_stop_navigation()
	if event is InputEventMouseMotion and _over_tools(event.position):
		# A fast pointer can enter and leave the toolbar between two frames.
		# Break at event time, before GUI consumes this motion, so reentry never
		# invents a straight paint segment across the skipped part of the path.
		previous = Vector3i(-1, -1, -1)
		surface_connect = false
		if pending_authored:
			pending_authored.break_segment()
		_stop_live_emitter()
	if event is InputEventMouseMotion and navigation_button != MOUSE_BUTTON_NONE:
		if not _over_tools(event.position):
			_navigate(event.relative, navigation_pan)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		cancel_pending_paint()
		_release_shortcuts()
		_reset_gesture()
		_drop_tool_anchor()
		_end_stroke()
		_stop_navigation()
		depth_scroll_fraction = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if _over_tools(event.position):
			depth_scroll_fraction = 0.0
			return
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if event.alt_pressed:
					cancel_pending_paint()
					_end_stroke()
					navigation_button = MOUSE_BUTTON_LEFT
					navigation_pan = event.shift_pressed
					orbiting = true
				elif navigation_button != MOUSE_BUTTON_NONE:
					return
				elif selecting:
					_select_corner(_target_at(event.position))
				elif tool_mode != "":
					_tool_click(target)
				elif capturing and not painting:
					_queue_pending_press(event.position)
				elif not capturing and (targeting_mode == TargetMode.SURFACE or _target_at(event.position).x >= 0):
					_invalidate_picks(false)
					stroke_target_mode = targeting_mode
					stroke_view = {"section": section, "axis": axis, "depth": depth}
					surface_connect = false
					stroke_radius = radius
					stroke_element = element
					stroke_erase = erase
					stroke_shape = shape
					stroke_thermal = thermal_tool
					if not testing:
						_begin_authored_edit()
					painting = true
					_sample(event.position)
			MOUSE_BUTTON_RIGHT:
				cancel_pending_paint()
				_end_stroke()
				navigation_button = MOUSE_BUTTON_RIGHT
				navigation_pan = event.shift_pressed
				orbiting = true
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
				cancel_pending_paint()
				_end_stroke()
				var sign_value := 1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1
				# Godot reports zero when this device has no precise wheel factor.
				var amount: float = event.factor if event.factor > 0.0 and is_finite(event.factor) else 1.0
				if event.shift_pressed:
					_wheel_depth(sign_value * amount)
				else:
					depth_scroll_fraction = 0.0
					_zoom(pow(1.0 / 0.9, clampf(sign_value * amount, -100.0, 100.0)))
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and pending_authored:
		_sample_pending(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and painting:
		_sample(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		var focused := get_viewport().gui_get_focus_owner()
		if focused is LineEdit or focused is TextEdit:
			return # Even an empty text Undo stack must not fall through to world Undo.
		if _shortcut_key(event, [KEY_Z]) == KEY_Z and (event.ctrl_pressed or event.meta_pressed) and not event.alt_pressed:
			_end_stroke()
			if event.shift_pressed:
				redo_edit()
			else:
				undo_edit()
			get_viewport().set_input_as_handled()
			return
		if event.ctrl_pressed or event.meta_pressed or event.alt_pressed or event.shift_pressed:
			return
		if event.keycode not in [KEY_P, KEY_N, KEY_R, KEY_0, KEY_COMMA, KEY_PERIOD, KEY_BACKSLASH, KEY_B, KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9, KEY_X, KEY_BRACKETLEFT, KEY_BRACKETRIGHT, KEY_V, KEY_F, KEY_C, KEY_L, KEY_K]:
			return
		_end_stroke()
		match event.keycode:
			KEY_P:
				toggle_test_pause()
			KEY_N:
				step_test()
			KEY_R, KEY_0, KEY_COMMA, KEY_PERIOD, KEY_BACKSLASH:
				# This editor owns build/test state. Legacy time hotkeys must not
				# advance the authored world behind the undo model.
				pass
			KEY_B:
				selection_toggle.button_pressed = not selection_toggle.button_pressed
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9:
				var id: int = palette.key_material(event.keycode - KEY_1 + 1) if palette else event.keycode - KEY_1 + 1
				if id > 0:
					element = id
					thermal_tool = ""
					_apply_default_shape()
				erase = false
			KEY_C:
				_cycle_shape()
			KEY_L:
				_toggle_tool("line")
			KEY_K:
				_toggle_tool("box")
			KEY_X:
				erase = not erase
			KEY_BRACKETLEFT:
				radius_input.value -= 1
			KEY_BRACKETRIGHT:
				radius_input.value += 1
			KEY_V:
				_face_plane()
			KEY_F:
				camera_target = Vector3.ZERO
				distance = 1.25
				yaw = 0.65
				pitch = -0.4
				_update_camera()
			_:
				return
		get_viewport().set_input_as_handled()


func _select_corner(cell: Vector3i) -> void:
	if cell.x < 0:
		return
	if corner_a.x < 0 or corner_b.x >= 0:
		corner_a = cell
		corner_b = Vector3i(-1, -1, -1)
		selection_mesh.hide()
		selection_status.text = "Corner 1: %s\nMove plane, then click corner 2" % str(cell)
		return
	corner_b = cell
	var lo := corner_a.min(corner_b)
	var hi := corner_a.max(corner_b) + Vector3i.ONE
	var size := hi - lo
	selection_mesh.position = ((Vector3(lo + hi) * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5) * sim.world_size()
	selection_mesh.scale = Vector3(size) * sim.world_size() / VoxelCodec.GRID
	selection_mesh.show()
	selection_status.text = "Region %s → %s\n%d × %d × %d cells (%d)" % [str(lo), str(hi - Vector3i.ONE), size.x, size.y, size.z, size.x * size.y * size.z]


func fill_selection() -> void:
	_end_stroke()
	if corner_a.x >= 0 and corner_b.x >= 0 and not capturing and not testing:
		var lo := corner_a.min(corner_b)
		var hi := corner_a.max(corner_b) + Vector3i.ONE
		var id := element
		_begin_authored_edit()
		sim.record_region(active_transaction, lo, hi, id)
		_end_stroke()


func _clear_history() -> void:
	undo_history.clear()
	redo_history.clear()
	undo_bytes = 0
	redo_bytes = 0


func _trim_history() -> void:
	var sizes := HistoryBudget.trim(undo_history, redo_history, undo_bytes, redo_bytes)
	undo_bytes = sizes.x
	redo_bytes = sizes.y


func cancel_pending_paint() -> void:
	pending_authored = null


func _queue_pending_press(mouse: Vector2) -> void:
	if testing or not _capture_accepts_pending or not _queued_editor_action.is_empty():
		edit_message = "Changing editor state; paint when it is ready."
		return
	if is_instance_valid(archive_panel) and (archive_panel._modal or not archive_panel.queued_dialog.is_empty()):
		return
	if pending_authored:
		pending_authored.warning = "An additional stroke was skipped while the previous edit was finishing."
		edit_message = "One stroke is already waiting; release and paint again when ready."
		return
	if targeting_mode == TargetMode.PLANE and _target_at(mouse).x < 0:
		return
	pending_authored = PendingGesture.new({"epoch": sim.edit_epoch, "mode": targeting_mode,
		"element": element, "radius": radius, "erase": erase, "thermal": thermal_tool, "shape": shape,
		"view": {"section": section, "axis": axis, "depth": depth}})
	_sample_pending(mouse)
	edit_message = "Stroke queued while the previous edit finishes."


func _sample_pending(mouse: Vector2) -> void:
	if not pending_authored or pending_authored.closed:
		return
	if _over_tools(mouse):
		pending_authored.break_segment()
		return
	if pending_authored.metadata.mode == TargetMode.SURFACE:
		pending_authored.add_ray(_ray_at(mouse, pending_authored.metadata.view))
	else:
		pending_authored.add_cell(_target_at(mouse))
	if pending_authored.limited:
		edit_message = "Pending stroke limit reached; only the recorded part will be painted."


func _resume_pending_paint() -> void:
	if not pending_authored or capturing:
		return
	var gesture: RefCounted = pending_authored
	pending_authored = null
	if testing or gesture.metadata.epoch != sim.edit_epoch or orbiting or navigation_button != MOUSE_BUTTON_NONE or not _queued_editor_action.is_empty():
		return
	if is_instance_valid(archive_panel) and (archive_panel._modal or not archive_panel.queued_dialog.is_empty()):
		return
	if gesture.samples.is_empty():
		return
	stroke_target_mode = gesture.metadata.mode
	stroke_element = gesture.metadata.element
	stroke_radius = gesture.metadata.radius
	stroke_erase = gesture.metadata.erase
	stroke_shape = gesture.metadata.get("shape", BrushScript.Shape.SPHERE)
	stroke_thermal = gesture.metadata.get("thermal", "")
	stroke_view = gesture.metadata.view
	_begin_authored_edit(gesture.warning)
	var mode: int = _brush_mode(stroke_erase)
	if stroke_target_mode == TargetMode.SURFACE:
		sim.record_surface_stroke(active_transaction, gesture.samples, stroke_radius, stroke_element, mode, active_transaction, stroke_shape)
		surface_connect = gesture.connect_next
	else:
		sim.record_stroke(active_transaction, gesture.centers(), stroke_radius, stroke_element, mode, active_transaction, stroke_shape, _stroke_axis())
		previous = gesture.last_cell()
	painting = not gesture.closed and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not painting:
		_end_stroke()


func _begin_authored_edit(warning: String = "") -> void:
	capturing = true
	_capture_accepts_pending = true
	edit_message = ""
	active_transaction = sim.begin_edit_transaction(func(result: Dictionary):
		if result.epoch != sim.edit_epoch:
			capturing = false
			_capture_accepts_pending = false
			cancel_pending_paint()
			return
		if not warning.is_empty():
			result.error = warning if result.error.is_empty() else result.error + "\n" + warning
		if result.valid and not result.regions.is_empty() and (not redo_history.is_empty() or not document.is_dirty()):
			# Only a changed construction branches history or marks a clean build
			# unsaved. This remains a bounded regional comparison, never world polling.
			if sim.inspect_edit_transaction(result, func(inspected: Dictionary):
				if inspected.epoch != sim.edit_epoch:
					capturing = false
					_capture_accepts_pending = false
					cancel_pending_paint()
					return
				if not inspected.valid:
					result.error = "Could not verify the new edit; marked unsaved and Redo cleared. Undo remains available."
				_complete_authored_edit(result, inspected.changed if inspected.valid else true)):
				return
			result.error = "Could not verify the new edit; marked unsaved and Redo cleared. Undo remains available."
		_complete_authored_edit(result, true))


func _complete_authored_edit(result: Dictionary, changed: bool) -> void:
	capturing = false
	_capture_accepts_pending = false
	last_edit_bytes = result.bytes
	edit_message = result.error
	if not result.valid:
		cancel_pending_paint()
		_clear_history()
		document.changed(result) # A failed capture may still have authored mutations.
	if result.valid and changed and not result.regions.is_empty():
		document.changed(result)
		redo_history.clear()
		redo_bytes = 0
		undo_history.append(result)
		undo_bytes += result.bytes
		_trim_history()
	result["changed"] = result.valid and changed and not result.regions.is_empty()
	_resume_pending_paint()
	edit_completed.emit(result)


func undo_edit() -> void:
	_history_action(false)


func redo_edit() -> void:
	_history_action(true)


func _history_action(redo: bool) -> void:
	if not redo and pending_authored:
		# The waiting stroke is the newest accepted authored intent. Undo consumes
		# that intent once; it must not also remove the earlier applied edit.
		cancel_pending_paint()
		edit_message = "Canceled the waiting stroke."
		return
	if testing or _wait_for_edit("redo" if redo else "undo"):
		return
	var source: Array[Dictionary] = redo_history if redo else undo_history
	if source.is_empty():
		return
	_drop_tool_anchor()
	var original: Dictionary = source.back()
	capturing = true
	_capture_accepts_pending = true
	edit_message = "Preparing Redo…" if redo else "Preparing Undo…"
	if not sim.reverse_edit_transaction(original, func(inverse: Dictionary):
		capturing = false
		_capture_accepts_pending = false
		if inverse.epoch != sim.edit_epoch:
			cancel_pending_paint()
			_clear_history()
			edit_message = "The world changed; history was cleared."
			return
		if not inverse.applied:
			cancel_pending_paint()
			# The original is still on its stack; failed inverse capture did not
			# mutate the world or consume the only recoverable history entry.
			edit_message = inverse.error
			edit_completed.emit(inverse)
			return
		source.pop_back()
		document.reversed(original, inverse, redo)
		if redo:
			redo_bytes -= original.bytes
			undo_history.append(inverse)
			undo_bytes += inverse.bytes
		else:
			undo_bytes -= original.bytes
			redo_history.append(inverse)
			redo_bytes += inverse.bytes
		_trim_history()
		last_edit_bytes = inverse.bytes
		edit_message = ""
		_resume_pending_paint()
		edit_completed.emit(inverse)):
		capturing = false
		_capture_accepts_pending = false
		edit_message = "This history is unavailable or belongs to another world; no action was applied."


func run_or_restore() -> void:
	_set_testing(not testing)


func _set_testing(desired: bool) -> void:
	# A repeated press on the still-visible Run button requests the same
	# phase; it must not become a Return after the pending capture completes.
	if testing == desired:
		return
	if _wait_for_edit("start_test" if desired else "return_build"):
		return
	if not desired:
		TimeController.paused = true
		sim.upload(build_snapshot, build_thermal)
		# This reset restores the exact authored revision, so its existing build
		# history remains applicable even though the runtime epoch advances.
		for transaction in undo_history + redo_history:
			transaction.epoch = sim.edit_epoch
		testing = false
		play_button.text = "Run experiment · Space"
	else:
		capturing = true
		_capture_accepts_pending = false
		var epoch: int = sim.edit_epoch
		var revision: int = sim.edit_revision
		read_world(_begin_test.bind(epoch, revision))


func _begin_test(bytes: PackedByteArray, thermal: PackedByteArray, epoch: int, revision: int) -> void:
	capturing = false
	if sim.edit_epoch != epoch or sim.edit_revision != revision:
		edit_message = "The build changed while preparing the experiment; run it again."
		return
	build_snapshot = bytes
	build_thermal = thermal
	edit_message = ""
	_drop_tool_anchor()
	testing = true
	TimeController.time_scale = speed_scale
	TimeController.paused = false
	play_button.text = "Return to build (restore) · Space"


func _target_at(mouse: Vector2) -> Vector3i:
	var inverse := sim.global_transform.affine_inverse()
	return Geometry.target(inverse * camera.project_ray_origin(mouse), inverse.basis * camera.project_ray_normal(mouse), axis, depth, VoxelCodec.GRID)


func _ray_at(mouse: Vector2, view: Dictionary = {}) -> Dictionary:
	var inverse := sim.global_transform.affine_inverse()
	return {"origin": inverse * camera.project_ray_origin(mouse),
		"direction": (inverse.basis * camera.project_ray_normal(mouse)).normalized(),
		"section": view.get("section", section), "axis": view.get("axis", axis), "depth": view.get("depth", depth)}


## Reject every pick still in flight. `clear` also drops the shown target,
## which is right when the world or the view changed under it; a stroke
## press keeps the target visible, so the marker never blinks at the click.
func _invalidate_picks(clear := true) -> void:
	pick_intent += 1
	if clear:
		pick_cache.clear()
		pick_shown_id = -1


## Placement-brief contract 3: one preview pick is issued every frame the
## pointer is over the scene, moving or not; requests carry increasing ids and
## only a newer id replaces the shown target, which stays until then. Preview
## is informational: painting re-picks against ordered GPU state, so authored
## edits do not hide it (only a world reset or an explicit invalidation does).
func _request_preview(mouse: Vector2) -> void:
	if pick_pending:
		return
	pick_pending = true
	pick_request_id += 1
	sim.request_surface_pick(_ray_at(mouse), radius, erase, _receive_pick.bind(pick_request_id, pick_intent))


func _receive_pick(result: Dictionary, id: int, intent: int) -> void:
	pick_pending = false
	if id <= pick_shown_id or intent != pick_intent or result.epoch != sim.edit_epoch:
		return
	pick_shown_id = id
	pick_cache = result


## Accept every motion event up to MAX_SAMPLES_PER_FRAME per frame, then every
## second, fourth, ... so the accepted stream stays evenly spread. Consecutive
## accepted samples are still joined by the face-connected DDA.
func _accept_sample() -> bool:
	_frame_samples += 1
	if _frame_samples <= MAX_SAMPLES_PER_FRAME:
		return true
	var stride := 1
	while _frame_samples > MAX_SAMPLES_PER_FRAME * stride:
		stride *= 2
	return _frame_samples % stride == 0


func _sample(mouse: Vector2) -> void:
	if not _accept_sample():
		return
	if testing:
		# Live input changes a source; only authoritative ticks may inject matter.
		_set_live_source(mouse)
		return
	if stroke_target_mode == TargetMode.SURFACE:
		var ray := _ray_at(mouse, stroke_view)
		ray["connect"] = surface_connect
		# Every accepted pointer sample is kept; the GPU resolves each in order and
		# joins consecutive targets (same face by a straight line, corners via the
		# edge). Toolbar crossings and misses break the line.
		if pending_surface.size() < MAX_SAMPLES_PER_FRAME:
			pending_surface.append(ray)
		else:
			pending_surface[-1] = ray
		surface_connect = true
		return
	var cell := _target_at(mouse)
	if cell.x < 0:
		previous = cell
		return
	if previous.x < 0:
		pending.append(cell)
	elif previous != cell:
		var line := Geometry.stroke(previous, cell)
		line.remove_at(0)
		pending.append_array(line)
	previous = cell


## Hover inspector: at most one 64-byte probe in flight, never a full readback.
func _update_probe(blocked: bool) -> void:
	if blocked or not sim.has_method("request_cell_probe"):
		probe_text = ""
		return
	if probe_pending:
		return
	var ray := _ray_at(get_viewport().get_mouse_position())
	probe_pending = true
	sim.request_cell_probe(ray.origin, ray.direction, _receive_probe.bind(sim.edit_epoch))


func _receive_probe(result: Dictionary, epoch: int) -> void:
	probe_pending = false
	probe_text = CellInspector.describe(result) if is_inside_tree() and sim.edit_epoch == epoch else ""


func _end_stroke(completed: bool = false) -> void:
	if pending_authored:
		pending_authored.closed = true
	if completed and live_emitter_signature != 0 and sim.has_method("finish_live_emitter"):
		sim.finish_live_emitter()
		live_emitter_signature = 0
	else:
		_stop_live_emitter()
	_flush()
	if active_transaction >= 0:
		sim.finish_edit_transaction(active_transaction)
		active_transaction = -1
	painting = false
	previous = Vector3i(-1, -1, -1)
	_last_thermal_center = Vector3i(-1, -1, -1)
	surface_connect = false
	_live_previous = Vector3i(-1, -1, -1)
	_live_surface_previous = {}


func _stop_live_emitter() -> void:
	if live_emitter_signature != 0 and sim != null and sim.has_method("clear_live_emitter"):
		sim.clear_live_emitter()
	live_emitter_signature = 0
	_live_previous = Vector3i(-1, -1, -1)
	_live_surface_previous = {}


func _update_live_emitter(over_ui: bool) -> void:
	if not sim.has_method("set_live_emitter"):
		return # the companion simulation checkpoint supplies authoritative cadence
	if not painting or not testing or over_ui or orbiting:
		_stop_live_emitter()
		return
	_set_live_source(get_viewport().get_mouse_position())


func _set_live_source(mouse: Vector2) -> void:
	if not painting or not testing or not sim.has_method("set_live_emitter"):
		return
	if _over_tools(mouse) or orbiting:
		_stop_live_emitter()
		return
	var surface: Dictionary = _ray_at(mouse, stroke_view) if stroke_target_mode == TargetMode.SURFACE else {}
	var center := _target_at(mouse) if surface.is_empty() else Vector3i.ZERO
	if surface.is_empty() and center.x < 0:
		_stop_live_emitter()
		return
	if stroke_thermal != "":
		# Heat and cool apply immediately at the pointer; there is no matter to
		# meter. Stamps are spaced by the brush radius, as in Build.
		if not surface.is_empty():
			if sim.has_method("paint_surface_thermal_stroke"):
				surface["connect"] = surface_connect
				surface_connect = true
				sim.paint_surface_thermal_stroke([surface], stroke_radius, _thermal_kelvin(stroke_thermal))
			return
		if center.x < 0:
			return
		var cells: Array[Vector3i] = [center]
		var picked := ThermalStroke.select(cells, stroke_radius, _last_thermal_center)
		_last_thermal_center = picked.last
		if not picked.centers.is_empty() and sim.has_method("paint_thermal_stroke"):
			sim.paint_thermal_stroke(picked.centers, stroke_radius, _thermal_kelvin(stroke_thermal))
		return
	var mode: int = _brush_mode(stroke_erase)
	_queue_live_path(center, surface, stroke_radius, stroke_element, mode)
	var signature := hash([center, stroke_radius, stroke_element, mode, surface, stroke_shape])
	if signature != live_emitter_signature:
		live_emitter_signature = signature
		sim.set_live_emitter(center, stroke_radius, stroke_element, mode, Emission.RATE, 1, surface, stroke_shape, _stroke_axis())


## A moving live brush lays a connected line: every cell the pointer crossed
## since its last sample gets one stamp inside the next authoritative tick, in
## addition to the held source's rate (a still brush keeps pouring by design).
func _queue_live_path(center: Vector3i, surface: Dictionary, brush_radius: int, material: int, mode: int) -> void:
	if surface.is_empty():
		_live_surface_previous = {}
		if sim.has_method("queue_live_path"):
			# The first sample's cell is part of the path too: the held source
			# may already have moved on before its first tick-owned stamp.
			var path: Array[Vector3i] = [center]
			if _live_previous.x >= 0 and center != _live_previous:
				path = Geometry.stroke(_live_previous, center)
				path.remove_at(0)
			if _live_previous.x < 0 or center != _live_previous:
				sim.queue_live_path(path, brush_radius, material, mode, 1, stroke_shape, _stroke_axis())
		_live_previous = center
		return
	_live_previous = Vector3i(-1, -1, -1)
	if sim.has_method("queue_live_surface_path"):
		var ray := surface.duplicate(true)
		ray["connect"] = not _live_surface_previous.is_empty()
		sim.queue_live_surface_path([ray], brush_radius, material, mode, 1, stroke_shape)
	_live_surface_previous = surface


func _flush() -> void:
	_frame_samples = 0
	# A stroke without an authored transaction must never bypass tick cadence.
	if testing or active_transaction < 0:
		pending_surface.clear()
		pending.clear()
		return
	if not pending_surface.is_empty() and sim != null:
		if stroke_thermal != "":
			if active_transaction >= 0 and sim.has_method("record_surface_thermal_stroke"):
				sim.record_surface_thermal_stroke(active_transaction, pending_surface, stroke_radius, _thermal_kelvin(stroke_thermal))
			pending_surface.clear()
			return
		var mode: int = _brush_mode(stroke_erase)
		if active_transaction >= 0:
			sim.record_surface_stroke(active_transaction, pending_surface, stroke_radius, stroke_element, mode, active_transaction, stroke_shape)
		pending_surface.clear()
	if not pending.is_empty() and sim != null:
		if stroke_thermal != "":
			# Space stamps along the path so stroke speed does not change the heat deposited.
			var picked := ThermalStroke.select(pending, stroke_radius, _last_thermal_center)
			_last_thermal_center = picked.last
			if active_transaction >= 0 and not picked.centers.is_empty() and sim.has_method("record_thermal_stroke"):
				sim.record_thermal_stroke(active_transaction, picked.centers, stroke_radius, _thermal_kelvin(stroke_thermal))
			pending.clear()
			return
		var mode: int = _brush_mode(stroke_erase)
		if active_transaction >= 0:
			sim.record_stroke(active_transaction, pending, stroke_radius, stroke_element, mode, active_transaction, stroke_shape, _stroke_axis())
		pending.clear()


## Fly navigation is an option, remembered across sessions beside the picture
## preference. Turning it off restores the orbit camera exactly: no velocity,
## no field-of-view boost, and the workplane, target and document are untouched.
func set_fly_enabled(value: bool) -> void:
	fly_enabled = value
	if _fly_motion == null and camera and sim:
		_fly_motion = FlyMotion.new(sim.world_size())
		if _base_fov <= 0.0:
			_base_fov = camera.fov
	if fly_toggle and fly_toggle.button_pressed != value:
		fly_toggle.set_pressed_no_signal(value)
	if _fly_motion:
		_fly_motion.stop()
	if not value and camera:
		camera.fov = _base_fov
	FlyPreference.store(value, self)


## A held W is a movement request only while the scene owns the keyboard. A
## focused text field (brush radius, ambient temperature), a modal, Test mode's
## own controls and lost focus all stop the camera instead of flying it.
func _fly_active() -> bool:
	if not fly_enabled or camera == null or not _ready_to_edit:
		return false
	var focused := get_viewport().gui_get_focus_owner()
	if focused is LineEdit or focused is TextEdit:
		return false
	if is_instance_valid(archive_panel) and (archive_panel._modal or not archive_panel.queued_dialog.is_empty()):
		return false
	return not Input.is_key_pressed(KEY_META) and not Input.is_key_pressed(KEY_CTRL) and not Input.is_key_pressed(KEY_ALT)


## Move the camera without touching the workplane, the pick contract or the
## authored document. Painting continues: a held drag keeps its stroke, and the
## next sample is joined by the usual face-connected path.
func _fly_step(delta: float) -> void:
	# Fixtures and alternative scenes build their own camera without the
	# editor's _ready; create the motion on demand so the option works there too.
	if _fly_motion == null:
		if camera == null or sim == null:
			return
		_fly_motion = FlyMotion.new(sim.world_size())
		if _base_fov <= 0.0:
			_base_fov = camera.fov
	if not _fly_active():
		_fly_motion.stop()
		if camera:
			camera.fov = _base_fov
		return
	var input: Vector3 = FlyMotion.input_vector(true)
	var sprinting := input != Vector3.ZERO and Input.is_key_pressed(KEY_SHIFT)
	var moved: Vector3 = _fly_motion.step(delta, camera.global_transform.basis, input, sprinting)
	if moved != Vector3.ZERO:
		# The orbit rig is defined by its target; flying moves that target with
		# the camera so orbiting afterwards pivots around the new view.
		camera_target += moved / sim.world_size()
		_update_camera()
		_invalidate_picks(false)
	camera.fov = _base_fov + _fly_motion.fov_boost


func _process(delta: float) -> void:
	if not _ready_to_edit:
		return
	_fly_step(delta)
	if painting and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_end_stroke()
	if navigation_button != MOUSE_BUTTON_NONE and not Input.is_mouse_button_pressed(navigation_button):
		_stop_navigation()
	# Hovering UI breaks the segment, avoiding a bridge across controls.
	var over_ui := get_viewport().gui_get_hovered_control() != null
	if over_ui:
		previous = Vector3i(-1, -1, -1)
		surface_connect = false
	if targeting_mode == TargetMode.SURFACE and not selecting:
		if not over_ui and not orbiting:
			_request_preview(get_viewport().get_mouse_position())
		target = pick_cache.target if pick_cache.get("valid", false) else Vector3i(-1, -1, -1)
	else:
		target = _target_at(get_viewport().get_mouse_position())
	guide.visible = show_workplane_grid and (targeting_mode == TargetMode.PLANE or selecting)
	marker.visible = target.x >= 0 and not over_ui and not orbiting
	if marker.visible:
		marker.position = ((Vector3(target) + Vector3.ONE * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5) * sim.world_size()
		marker.scale = Vector3.ONE * (2 * radius + 1) * sim.world_size() / VoxelCodec.GRID
		_request_stamp_preview()
	elif not _preview_cells.is_empty():
		_clear_stamp_preview()
	if preview_mesh:
		preview_mesh.visible = marker.visible
	if tool_box_mesh == null:
		pass # test fixtures without overlay meshes
	elif tool_mode == "box" and tool_anchor.x >= 0 and target.x >= 0:
		var lo := tool_anchor.min(target)
		var hi := tool_anchor.max(target) + Vector3i.ONE
		tool_box_mesh.position = ((Vector3(lo + hi) * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5) * sim.world_size()
		tool_box_mesh.scale = Vector3(hi - lo) * sim.world_size() / VoxelCodec.GRID
		tool_box_mesh.visible = true
	elif tool_mode == "line" and tool_anchor.x >= 0:
		tool_box_mesh.position = ((Vector3(tool_anchor) + Vector3.ONE * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5) * sim.world_size()
		tool_box_mesh.scale = Vector3.ONE * (2 * radius + 1) * sim.world_size() / VoxelCodec.GRID
		tool_box_mesh.visible = true
	else:
		tool_box_mesh.visible = false
	_update_live_emitter(over_ui)
	_update_probe(over_ui or orbiting or painting or selecting)
	_flush()
	status.text = "%s · %s · r=%d cells\nPlane %s=%d · target %s\n%.0f FPS · %s\n%s" % [("HEAT" if thermal_tool == "heat" else "COOL") if thermal_tool != "" else ("ERASE" if erase else "Add into empty space"), Elements.TABLE[element].name, radius, ["X", "Y", "Z"][axis], depth, str(target) if marker.visible else "—", Engine.get_frames_per_second(), "Preparing edit…" if capturing else _test_phase(), "Live edits reset on return; no live undo" if testing else "%d undo · %d redo" % [undo_history.size(), redo_history.size()]]
	if edit_message != "":
		status.text += "\n" + edit_message
	if targeting_mode == TargetMode.SURFACE and not section_action.visible:
		status.text += "\n" + _surface_feedback()
	if not probe_text.is_empty():
		status.text += "\n" + probe_text
