extends SceneTree
## Brush shape selection (docs/milestone/placement-brief.md contract 5): solids
## default to a cube and flowing materials to a sphere when the material
## changes, a session override sticks, C cycles, and the frozen stroke metadata
## carries the shape and workplane axis into authored and live strokes.
##   godot --headless --path . -s res://tests/milestone/brush_shape.gd
const BrushScript := preload("res://scripts/sim/brush.gd")
var failures := 0
var checks := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])
func key(lab: Node, code: int) -> void:
	var event := InputEventKey.new()
	event.keycode = code
	event.pressed = true
	lab._unhandled_input(event)
func run() -> void:
	root.size = Vector2i(1280, 800)
	var lab = load("res://tests/milestone/paint_tools_lab.gd").new()
	root.add_child(lab)
	await process_frame
	check(BrushScript.default_shape(Elements.Id.WALL) == BrushScript.Shape.CUBE and BrushScript.default_shape(Elements.Id.WOOD) == BrushScript.Shape.CUBE,
		"immovable solids default to the cube brush")
	check(BrushScript.default_shape(Elements.Id.SAND) == BrushScript.Shape.SPHERE and BrushScript.default_shape(Elements.Id.WATER) == BrushScript.Shape.SPHERE and BrushScript.default_shape(Elements.Id.FIRE) == BrushScript.Shape.SPHERE,
		"powders, liquids and gases default to the sphere brush")
	check(BrushScript.default_shape(-1) == BrushScript.Shape.SPHERE and BrushScript.default_shape(Elements.count()) == BrushScript.Shape.SPHERE, "out-of-range ids fall back to the sphere")
	lab._choose_material(Elements.Id.WALL)
	check(lab.shape == BrushScript.Shape.CUBE and lab.shape_button.text.begins_with("Cube"), "choosing Wall selects the cube and labels the button")
	lab._choose_material(Elements.Id.SAND)
	check(lab.shape == BrushScript.Shape.SPHERE, "choosing Sand returns to the sphere while no override is set")
	key(lab, KEY_C)
	check(lab.shape == BrushScript.Shape.CUBE and lab.shape_overridden, "C cycles sphere to cube and marks a session override")
	key(lab, KEY_C)
	check(lab.shape == BrushScript.Shape.DISC, "C cycles cube to disc")
	lab._choose_material(Elements.Id.WATER)
	check(lab.shape == BrushScript.Shape.DISC, "a session override survives a material change")
	key(lab, KEY_C)
	check(lab.shape == BrushScript.Shape.SPHERE, "C cycles disc back to sphere")
	lab.shape_button.pressed.emit()
	check(lab.shape == BrushScript.Shape.CUBE, "the Shape button cycles like the key")
	key(lab, KEY_2)
	check(lab.element == lab.palette.key_material(2) and lab.shape == BrushScript.Shape.CUBE, "number keys change the material but keep the overridden shape")
	# Frozen metadata: a stroke uses the shape and workplane axis captured at press.
	lab.active_transaction = 9
	lab.stroke_shape = BrushScript.Shape.DISC
	lab.stroke_view = {"section": false, "axis": 0, "depth": 5}
	lab.stroke_element = Elements.Id.SAND
	lab.stroke_radius = 2
	lab.pending.append(Vector3i(12, 12, 12))
	lab._flush()
	var record: Array = lab.sim.records[-1]
	check(record[6] == BrushScript.Shape.DISC and record[7] == 0, "authored stroke carries the frozen shape and the stroke view's plane axis")
	lab.shape = BrushScript.Shape.SPHERE
	lab.pending.append(Vector3i(13, 12, 12))
	lab._flush()
	check(lab.sim.records[-1][6] == BrushScript.Shape.DISC, "changing the shape mid-stroke does not change the frozen stroke shape")
	lab.testing = true
	lab.painting = true
	lab.stroke_shape = BrushScript.Shape.CUBE
	lab.stroke_view = {"section": false, "axis": 2, "depth": 64}
	lab._sample(Vector2(730, 400))
	check(not lab.sim.source.is_empty() and lab.sim.source.shape == BrushScript.Shape.CUBE and lab.sim.source.axis == 2, "live source carries the frozen shape and axis")
	lab.queue_free()
	await process_frame
	print("Brush shape CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
