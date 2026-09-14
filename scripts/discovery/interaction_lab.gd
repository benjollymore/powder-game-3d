extends Node3D
## Runnable experiment using the production GPU state, brush kernel and renderer.
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
const SimScene := preload("res://scenes/sim_volume.tscn")
const Emission := preload("res://scripts/discovery/brush_emission.gd")
const HistoryBudget := preload("res://scripts/editor/history_budget.gd")
const PendingGesture := preload("res://scripts/editor/pending_gesture.gd")
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
var pick_signature := 0
var pick_cache := {}
var last_pick_ms := 0
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
var radius_input: SpinBox
var tools_panel: PanelContainer
var camera_target := Vector3.ZERO # box widths, independent of simulation size
var navigation_button := MOUSE_BUTTON_NONE
var navigation_pan := false
var depth_scroll_fraction := 0.0
var last_depth_scroll_ms := 0
const GESTURE_IDLE_MS := 350
var gesture_owner := -1 # -1: no sequence, 0: tools, 1: scene
var last_gesture_ms := -1
var gesture_trace := false
var _space_owned := false


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
	marker = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	marker.mesh = sphere
	marker.material_override = _overlay_material(Color(1.0, 0.78, 0.25, 0.42))
	add_child(marker)
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
	_face_plane()
	_update_plane()
	# Upload queues behind GPU initialization; no CPU state mirror is retained.
	reset_container()
	_ready_to_edit = true


func _exit_tree() -> void:
	cancel_pending_paint()
	if _owns_time_input and is_instance_valid(TimeController):
		TimeController.set_process_unhandled_input(_previous_time_input)
	_owns_time_input = false


## File payloads are validated by WorldArchive before reaching this boundary.
## Replacement starts a new authored world, never a partial runtime rewind.
func replace_authored(bytes: PackedByteArray) -> bool:
	if capturing or painting or bytes.size() != VoxelCodec.GRID * VoxelCodec.GRID * VoxelCodec.GRID * 4:
		return false
	_end_stroke()
	_queued_editor_action = ""
	_invalidate_picks()
	_reset_gesture()
	_stop_navigation()
	TimeController.paused = true
	testing = false
	_clear_history()
	last_edit_bytes = 0
	edit_message = ""
	build_snapshot.clear()
	corner_a = Vector3i(-1, -1, -1)
	corner_b = Vector3i(-1, -1, -1)
	selecting = false
	selection_toggle.button_pressed = false
	selection_mesh.visible = false
	selection_status.text = "Region: no corners selected"
	play_button.text = "Run experiment · Space"
	sim.upload(bytes)
	return true


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
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
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
	var material_row := HBoxContainer.new()
	column.add_child(material_row)
	for id in [Elements.Id.SAND, Elements.Id.WATER, Elements.Id.WALL]:
		_add_material_button(material_row, id)
	var more := CheckButton.new()
	more.text = "More materials"
	column.add_child(more)
	var extra := GridContainer.new()
	extra.columns = 3
	extra.visible = false
	column.add_child(extra)
	more.toggled.connect(func(enabled): extra.visible = enabled)
	for id in [Elements.Id.OIL, Elements.Id.WOOD, Elements.Id.PLANT, Elements.Id.FIRE, Elements.Id.STEAM, Elements.Id.SMOKE]:
		_add_material_button(extra, id)
	var brush_row := HBoxContainer.new()
	column.add_child(brush_row)
	var radius_label := Label.new()
	radius_label.text = "Brush radius  "
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
	erase_button.text = "Erase · X"
	erase_button.toggle_mode = true
	erase_button.pressed.connect(func():
		_end_stroke()
		erase = not erase)
	brush_row.add_child(erase_button)
	play_button = Button.new()
	play_button.text = "Run experiment · Space"
	play_button.pressed.connect(run_or_restore)
	column.add_child(play_button)
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
	var reset := Button.new()
	reset.text = "Reset container (discards edits)"
	reset.pressed.connect(reset_container)
	advanced_tools.add_child(reset)
	var empty := Button.new()
	empty.text = "Empty build (discards edits)"
	empty.pressed.connect(func(): call("new_empty_build"))
	advanced_tools.add_child(empty)
	var controls := Label.new()
	controls.add_theme_font_size_override("font_size", 14)
	controls.text = "Drag: paint · two fingers: orbit · pinch: zoom\nShift + two fingers: pan · Option + drag: orbit"
	var secondary_controls := Label.new()
	secondary_controls.add_theme_font_size_override("font_size", 14)
	secondary_controls.text = "Option + Shift + drag: pan · RMB/wheel work too\nPlane: −/+ above · Shift-wheel · [ ] brush size\n1 wall · 2 sand · 3 water · X erase · F angle"
	advanced_tools.add_child(secondary_controls)
	controls.tooltip_text = controls.text + "\n" + secondary_controls.text
	column.add_child(controls)
	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size.x = 300
	column.add_child(status)
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
	_refresh_palette()


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
		material_buttons[id].set_pressed_no_signal(id == element and not erase)
	if erase_button:
		erase_button.set_pressed_no_signal(erase)


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
	var n := VoxelCodec.GRID
	var data := WorldBuilder.empty()
	WorldBuilder.fill_bowl(data, Vector3i(n / 4, n / 6, n / 4), Vector3i(n * 3 / 4, n * 2 / 3, n * 3 / 4), maxi(2, n / 64))
	WorldBuilder.fill_box(data, Vector3i(n / 3, n / 5, n / 3), Vector3i(n * 2 / 3, n / 3, n * 2 / 3), Elements.Id.WATER)
	replace_authored(data.to_byte_array())


func new_empty_build() -> void:
	if not _wait_for_edit("empty"):
		replace_authored(WorldBuilder.empty().to_byte_array())


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


func _set_target_mode(value: int) -> void:
	cancel_pending_paint()
	_end_stroke()
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


func _input(event: InputEvent) -> void:
	if event is InputEventKey and _route_space(event):
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
		_space_owned = false
		_reset_gesture()
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
				elif capturing and not painting:
					_queue_pending_press(event.position)
				elif not capturing and (targeting_mode == TargetMode.SURFACE or _target_at(event.position).x >= 0):
					_invalidate_picks()
					stroke_target_mode = targeting_mode
					stroke_view = {"section": section, "axis": axis, "depth": depth}
					surface_connect = false
					stroke_radius = radius
					stroke_element = element
					stroke_erase = erase
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
		_end_stroke()
		match event.keycode:
			KEY_Z:
				if event.ctrl_pressed or event.meta_pressed:
					if event.shift_pressed:
						redo_edit()
					else:
						undo_edit()
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
			KEY_1, KEY_2, KEY_3:
				element = event.keycode - KEY_1 + 1
				erase = false
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
		"element": element, "radius": radius, "erase": erase,
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
	stroke_view = gesture.metadata.view
	_begin_authored_edit(gesture.warning)
	var mode: int = sim.BrushMode.ERASE if stroke_erase else sim.BrushMode.ONLY_AIR
	if stroke_target_mode == TargetMode.SURFACE:
		sim.record_surface_stroke(active_transaction, gesture.samples, stroke_radius, stroke_element, mode, active_transaction)
		surface_connect = gesture.connect_next
	else:
		sim.record_stroke(active_transaction, gesture.centers(), stroke_radius, stroke_element, mode, active_transaction)
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
		if result.valid and not result.regions.is_empty() and not redo_history.is_empty():
			# Only a changed construction branches history. A miss or an ONLY_AIR
			# brush over occupied matter must not discard the remaining future.
			if sim.inspect_edit_transaction(result, func(inspected: Dictionary):
				if inspected.epoch != sim.edit_epoch:
					capturing = false
					_capture_accepts_pending = false
					cancel_pending_paint()
					return
				if not inspected.valid:
					result.error = "Could not verify the new edit; Redo was cleared. Its Undo remains available."
				_complete_authored_edit(result, inspected.changed if inspected.valid else true)):
				return
			result.error = "Could not verify the new edit; Redo was cleared. Its Undo remains available."
		_complete_authored_edit(result, true))


func _complete_authored_edit(result: Dictionary, changed: bool) -> void:
	capturing = false
	_capture_accepts_pending = false
	last_edit_bytes = result.bytes
	edit_message = result.error
	if not result.valid:
		cancel_pending_paint()
		_clear_history()
	if result.valid and changed and not result.regions.is_empty():
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
		sim.upload(build_snapshot)
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
		sim.request_readback(func(bytes: PackedByteArray):
			capturing = false
			if sim.edit_epoch != epoch or sim.edit_revision != revision:
				edit_message = "The build changed while preparing the experiment; run it again."
				return
			build_snapshot = bytes
			edit_message = ""
			testing = true
			TimeController.time_scale = 1.0
			TimeController.paused = false
			play_button.text = "Return to build (restore) · Space")


func _target_at(mouse: Vector2) -> Vector3i:
	var inverse := sim.global_transform.affine_inverse()
	return Geometry.target(inverse * camera.project_ray_origin(mouse), inverse.basis * camera.project_ray_normal(mouse), axis, depth, VoxelCodec.GRID)


func _ray_at(mouse: Vector2, view: Dictionary = {}) -> Dictionary:
	var inverse := sim.global_transform.affine_inverse()
	return {"origin": inverse * camera.project_ray_origin(mouse),
		"direction": (inverse.basis * camera.project_ray_normal(mouse)).normalized(),
		"section": view.get("section", section), "axis": view.get("axis", axis), "depth": view.get("depth", depth)}


func _invalidate_picks() -> void:
	pick_intent += 1
	pick_signature = 0
	pick_cache.clear()


func _request_preview(mouse: Vector2) -> void:
	var ray := _ray_at(mouse)
	var signature := hash([ray, radius, erase, sim.edit_epoch, 0 if testing else sim.edit_revision])
	if signature != pick_signature:
		pick_intent += 1
		pick_signature = signature
		pick_cache.clear()
	if pick_pending or (not pick_cache.is_empty() and (not testing or Time.get_ticks_msec() - last_pick_ms < 50)):
		return
	pick_pending = true
	last_pick_ms = Time.get_ticks_msec()
	var intent := pick_intent
	sim.request_surface_pick(ray, radius, erase, func(result: Dictionary): _receive_pick(result, intent))


func _receive_pick(result: Dictionary, intent: int) -> void:
	pick_pending = false
	if intent != pick_intent or result.epoch != sim.edit_epoch or (not testing and result.revision != sim.edit_revision):
		return
	pick_cache = result


func _sample(mouse: Vector2) -> void:
	if testing:
		# Live input changes a source; only authoritative ticks may inject matter.
		_set_live_source(mouse)
		return
	if stroke_target_mode == TargetMode.SURFACE:
		var ray := _ray_at(mouse, stroke_view)
		ray["connect"] = surface_connect
		# Retain the first and latest pointer sample per frame. GPU-resolved points
		# on the same face are joined; depth/normal discontinuities break the line.
		if pending_surface.size() >= 2:
			pending_surface[1] = ray
		else:
			pending_surface.append(ray)
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
	surface_connect = false


func _stop_live_emitter() -> void:
	if live_emitter_signature != 0 and sim != null and sim.has_method("clear_live_emitter"):
		sim.clear_live_emitter()
	live_emitter_signature = 0


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
	var mode: int = sim.BrushMode.ERASE if stroke_erase else sim.BrushMode.ONLY_AIR
	var signature := hash([center, stroke_radius, stroke_element, mode, surface])
	if signature != live_emitter_signature:
		live_emitter_signature = signature
		sim.set_live_emitter(center, stroke_radius, stroke_element, mode, Emission.RATE, 1, surface)


func _flush() -> void:
	# A stroke without an authored transaction must never bypass tick cadence.
	if testing or active_transaction < 0:
		pending_surface.clear()
		pending.clear()
		return
	if not pending_surface.is_empty() and sim != null:
		var mode: int = sim.BrushMode.ERASE if stroke_erase else sim.BrushMode.ONLY_AIR
		if active_transaction >= 0:
			sim.record_surface_stroke(active_transaction, pending_surface, stroke_radius, stroke_element, mode, active_transaction)
		pending_surface.clear()
	if not pending.is_empty() and sim != null:
		var mode: int = sim.BrushMode.ERASE if stroke_erase else sim.BrushMode.ONLY_AIR
		if active_transaction >= 0:
			sim.record_stroke(active_transaction, pending, stroke_radius, stroke_element, mode, active_transaction)
		pending.clear()


func _process(delta: float) -> void:
	if not _ready_to_edit:
		return
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
	_update_live_emitter(over_ui)
	_flush()
	status.text = "%s · %s · r=%d cells\nPlane %s=%d · target %s\n%.0f FPS · %s\n%s" % ["ERASE" if erase else "Add into empty space", Elements.TABLE[element].name, radius, ["X", "Y", "Z"][axis], depth, str(target) if marker.visible else "—", Engine.get_frames_per_second(), "Preparing edit…" if capturing else _test_phase(), "Live edits reset on return; no live undo" if testing else "%d undo · %d redo" % [undo_history.size(), redo_history.size()]]
	if edit_message != "":
		status.text += "\n" + edit_message
	if targeting_mode == TargetMode.SURFACE and not section_action.visible:
		status.text += "\n" + _surface_feedback()
