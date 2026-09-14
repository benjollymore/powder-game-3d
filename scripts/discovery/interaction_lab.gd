extends Node3D
## Runnable experiment using the production GPU state, brush kernel and renderer.
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
const SimScene := preload("res://scenes/sim_volume.tscn")

var sim: Node3D
var camera: Camera3D
var axis := 2
var depth: int
var radius := 3
var element := Elements.Id.WATER
var erase := false
var section := true
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
var undo_history: Array[PackedByteArray] = []
var play_button: Button
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
	_face_plane()
	_update_plane()
	# Upload queues behind GPU initialization; no CPU state mirror is retained.
	reset_container()
	_ready_to_edit = true


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
	column.add_theme_constant_override("separation", 8)
	scroll.add_child(column)
	var title := Label.new()
	title.text = "  PAINT & PLAY  /  discovery prototype  "
	column.add_child(title)
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
	var material_row := HBoxContainer.new()
	column.add_child(material_row)
	column.move_child(material_row, 1)
	selection_toggle = CheckButton.new()
	selection_toggle.text = "Region tool · B (click two corners)"
	selection_toggle.toggled.connect(func(enabled):
		_end_stroke()
		selecting = enabled)
	column.add_child(selection_toggle)
	selection_status = Label.new()
	selection_status.text = "Region: no corners selected"
	column.add_child(selection_status)
	var fill := Button.new()
	fill.text = "Fill selected region into air"
	fill.pressed.connect(fill_selection)
	column.add_child(fill)
	for id in [Elements.Id.WALL, Elements.Id.SAND, Elements.Id.WATER]:
		var button := Button.new()
		button.text = Elements.TABLE[id].name
		button.pressed.connect(func():
			_end_stroke()
			element = id
			erase = false)
		material_row.add_child(button)
	var brush_row := HBoxContainer.new()
	column.add_child(brush_row)
	column.move_child(brush_row, 2)
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
	var erase_button := Button.new()
	erase_button.text = "Paint / erase · X"
	erase_button.pressed.connect(func():
		_end_stroke()
		erase = not erase)
	brush_row.add_child(erase_button)
	var cut := CheckButton.new()
	cut.text = "Section view (positive side hidden)"
	cut.button_pressed = section
	cut.toggled.connect(func(enabled):
		section = enabled
		_update_plane())
	column.add_child(cut)
	var undo := Button.new()
	undo.text = "Undo build edit · Ctrl/Cmd Z"
	undo.pressed.connect(undo_edit)
	column.add_child(undo)
	play_button = Button.new()
	play_button.text = "Run experiment · Space"
	play_button.pressed.connect(run_or_restore)
	column.add_child(play_button)
	column.move_child(play_button, 3)
	var navigation_row := HBoxContainer.new()
	column.add_child(navigation_row)
	column.move_child(navigation_row, 4)
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
	var reset := Button.new()
	reset.text = "Reset container (discards edits)"
	reset.pressed.connect(reset_container)
	column.add_child(reset)
	var controls := Label.new()
	controls.add_theme_font_size_override("font_size", 14)
	controls.text = "Drag: paint · two fingers: orbit · pinch: zoom\nShift + two fingers: pan · Option + drag: orbit\nOption + Shift + drag: pan · RMB/wheel work too\nPlane: −/+ above · Shift-wheel · [ ] brush size\n1 wall · 2 sand · 3 water · X erase · F angle"
	column.add_child(controls)
	status = Label.new()
	column.add_child(status)


func reset_container() -> void:
	if capturing:
		return
	_end_stroke()
	testing = false
	undo_history.clear()
	build_snapshot.clear()
	if play_button:
		play_button.text = "Run experiment · Space"
	TimeController.paused = true
	var n := VoxelCodec.GRID
	var data := WorldBuilder.empty()
	WorldBuilder.fill_bowl(data, Vector3i(n / 4, n / 6, n / 4), Vector3i(n * 3 / 4, n * 2 / 3, n * 3 / 4), maxi(2, n / 64))
	WorldBuilder.fill_box(data, Vector3i(n / 3, n / 5, n / 3), Vector3i(n * 2 / 3, n / 3, n * 2 / 3), Elements.Id.WATER)
	sim.upload(data.to_byte_array())


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
			_end_stroke()
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
				elif not capturing and _target_at(event.position).x >= 0:
					stroke_radius = radius
					stroke_element = element
					stroke_erase = erase
					if not testing:
						_capture_edit()
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
			KEY_R, KEY_N, KEY_0, KEY_COMMA, KEY_PERIOD, KEY_BACKSLASH:
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
		_capture_edit(func(): sim.paint_region(lo, hi, id))


func _capture_edit(after: Callable = Callable()) -> void:
	capturing = true
	sim.request_readback(func(bytes: PackedByteArray):
		undo_history.append(bytes)
		# Discovery fallback: cap whole-volume undo to 128 MiB, at least one edit.
		var limit := maxi(1, 134217728 / bytes.size())
		while undo_history.size() > limit:
			undo_history.pop_front()
		capturing = false
		if after.is_valid():
			after.call()
		_flush())


func undo_edit() -> void:
	if capturing or testing:
		return
	_end_stroke()
	if not undo_history.is_empty():
		sim.upload(undo_history.pop_back())


func run_or_restore() -> void:
	if capturing:
		return
	_end_stroke()
	if testing:
		TimeController.paused = true
		sim.upload(build_snapshot)
		testing = false
		play_button.text = "Run experiment · Space"
	else:
		capturing = true
		sim.request_readback(func(bytes: PackedByteArray):
			build_snapshot = bytes
			capturing = false
			testing = true
			TimeController.time_scale = 1.0
			TimeController.paused = false
			play_button.text = "Return to build (restore) · Space")


func _target_at(mouse: Vector2) -> Vector3i:
	var inverse := sim.global_transform.affine_inverse()
	return Geometry.target(inverse * camera.project_ray_origin(mouse), inverse.basis * camera.project_ray_normal(mouse), axis, depth, VoxelCodec.GRID)


func _sample(mouse: Vector2) -> void:
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


func _end_stroke() -> void:
	_flush()
	painting = false
	previous = Vector3i(-1, -1, -1)


func _flush() -> void:
	if not pending.is_empty() and sim != null and not capturing:
		sim.paint_stroke(pending, stroke_radius, stroke_element, sim.BrushMode.ERASE if stroke_erase else sim.BrushMode.ONLY_AIR)
		pending.clear()


func _process(_delta: float) -> void:
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
	target = _target_at(get_viewport().get_mouse_position())
	marker.visible = target.x >= 0 and not over_ui and not orbiting
	if marker.visible:
		marker.position = ((Vector3(target) + Vector3.ONE * 0.5) / VoxelCodec.GRID - Vector3.ONE * 0.5) * sim.world_size()
		marker.scale = Vector3.ONE * (2 * radius + 1) * sim.world_size() / VoxelCodec.GRID
	_flush()
	status.text = "%s · %s · r=%d cells\nPlane %s=%d · target %s\n%.0f FPS · %s\n%s" % ["ERASE" if erase else "Add into empty space", Elements.TABLE[element].name, radius, ["X", "Y", "Z"][axis], depth, str(target) if marker.visible else "—", Engine.get_frames_per_second(), "Preparing edit…" if capturing else ("PLAYING" if testing else "BUILD"), "Live edits reset on return; no live undo" if testing else "%d build edits can be undone" % undo_history.size()]
