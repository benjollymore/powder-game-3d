extends Node3D
## Runnable experiment using the production GPU state, brush kernel and renderer.
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
const SimScene := preload("res://scenes/sim_volume.tscn")
const Emission := preload("res://scripts/discovery/brush_emission.gd")
enum TargetMode { PLANE, SURFACE }
var targeting_mode := TargetMode.PLANE
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
var _editor_action_scheduled := false
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


func _ready() -> void:
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
	guide.material_override = _overlay_material(Color(0.34, 0.75, 0.95, 0.25))
	add_child(guide)
	selection_mesh = MeshInstance3D.new()
	selection_mesh.mesh = BoxMesh.new()
	selection_mesh.material_override = _overlay_material(Color(0.6, 1.0, 0.5, 0.16))
	selection_mesh.visible = false
	add_child(selection_mesh)
	_build_ui()
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
	undo_history.clear()
	undo_bytes = 0
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
	var undo := Button.new()
	undo.text = "Undo build edit · Ctrl/Cmd Z"
	undo.pressed.connect(undo_edit)
	column.add_child(undo)
	var target_row := HBoxContainer.new()
	column.add_child(target_row)
	var target_label := Label.new()
	target_label.text = "Paint on  "
	target_row.add_child(target_label)
	var target_choice := OptionButton.new()
	target_choice.add_item("Workplane", TargetMode.PLANE)
	target_choice.add_item("Material surface", TargetMode.SURFACE)
	target_choice.item_selected.connect(func(value):
		_end_stroke()
		targeting_mode = value
		_invalidate_picks())
	target_row.add_child(target_choice)
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
	advanced_toggle.text = "Construction & section tools"
	column.add_child(advanced_toggle)
	advanced_tools = VBoxContainer.new()
	advanced_tools.visible = false
	column.add_child(advanced_tools)
	advanced_toggle.toggled.connect(_set_advanced)
	selection_toggle = CheckButton.new()
	selection_toggle.text = "Select region · B (two corners)"
	selection_toggle.toggled.connect(func(enabled):
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
	var cut := CheckButton.new()
	cut.text = "Section view (positive side hidden)"
	cut.button_pressed = section
	cut.toggled.connect(func(enabled):
		_end_stroke()
		section = enabled
		_update_plane())
	advanced_tools.add_child(cut)
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
	controls.text = "Drag: paint · two fingers: orbit · pinch: zoom\nShift + two fingers: pan · Option + drag: orbit\nOption + Shift + drag: pan · RMB/wheel work too\nPlane: −/+ above · Shift-wheel · [ ] brush size\n1 wall · 2 sand · 3 water · X erase · F angle"
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
	_end_stroke()
	if not capturing:
		_queued_editor_action = ""
		return false
	_queued_editor_action = action
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
	match action:
		"undo": undo_edit()
		"run": run_or_restore()
		"reset": reset_container()
		"empty": new_empty_build()


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


func _input(event: InputEvent) -> void:
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
	if event is InputEventMouseMotion and navigation_button != MOUSE_BUTTON_NONE:
		if not _over_tools(event.position):
			_navigate(event.relative, navigation_pan)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
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
					_end_stroke()
					navigation_button = MOUSE_BUTTON_LEFT
					navigation_pan = event.shift_pressed
					orbiting = true
				elif navigation_button != MOUSE_BUTTON_NONE:
					return
				elif selecting:
					_select_corner(_target_at(event.position))
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
				_end_stroke()
				navigation_button = MOUSE_BUTTON_RIGHT
				navigation_pan = event.shift_pressed
				orbiting = true
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
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
	elif event is InputEventMouseMotion and painting:
		_sample(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		_end_stroke()
		match event.keycode:
			KEY_SPACE:
				run_or_restore()
			KEY_Z:
				if event.ctrl_pressed or event.meta_pressed:
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


func _begin_authored_edit() -> void:
	capturing = true
	edit_message = ""
	active_transaction = sim.begin_edit_transaction(func(result: Dictionary):
		capturing = false
		if result.epoch != sim.edit_epoch:
			return
		last_edit_bytes = result.bytes
		edit_message = result.error
		if not result.valid:
			undo_history.clear()
			undo_bytes = 0
		if not result.regions.is_empty():
			undo_history.append(result)
			undo_bytes += result.bytes
		while undo_bytes > 128 * 1024 * 1024 and not undo_history.is_empty():
			var discarded: Dictionary = undo_history.pop_front()
			undo_bytes -= discarded.bytes
		edit_completed.emit(result))


func undo_edit() -> void:
	if testing or _wait_for_edit("undo"):
		return
	if not undo_history.is_empty():
		var result: Dictionary = undo_history.pop_back()
		undo_bytes -= result.bytes
		if not sim.restore_edit_transaction(result):
			edit_message = "This edit belongs to a different world; undo was skipped."


func run_or_restore() -> void:
	if _wait_for_edit("run"):
		return
	if testing:
		TimeController.paused = true
		sim.upload(build_snapshot)
		# This reset restores the exact authored revision, so its existing build
		# history remains applicable even though the runtime epoch advances.
		for transaction in undo_history:
			transaction.epoch = sim.edit_epoch
		testing = false
		play_button.text = "Run experiment · Space"
	else:
		capturing = true
		var epoch: int = sim.edit_epoch
		var revision: int = sim.edit_revision
		sim.request_readback(func(bytes: PackedByteArray):
			capturing = false
			if sim.edit_epoch != epoch or sim.edit_revision != revision:
				edit_message = "The build changed while preparing the experiment; run it again."
				return
			build_snapshot = bytes
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
	status.text = "%s · %s · r=%d cells\nPlane %s=%d · target %s\n%.0f FPS · %s\n%s" % ["ERASE" if erase else "Add into empty space", Elements.TABLE[element].name, radius, ["X", "Y", "Z"][axis], depth, str(target) if marker.visible else "—", Engine.get_frames_per_second(), "Preparing edit…" if capturing else _test_phase(), "Live edits reset on return; no live undo" if testing else "%d build edits can be undone" % undo_history.size()]
	if edit_message != "":
		status.text += "\n" + edit_message
	if targeting_mode == TargetMode.SURFACE:
		status.text += "\n" + ("Finding surface…" if pick_pending and pick_cache.is_empty() else "Surface: add outside · erase hit material")
