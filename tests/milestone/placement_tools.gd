extends SceneTree
## Two-click Line and Box tools (docs/milestone/placement-brief.md contract 7)
## on the fake simulator: key and button toggles, anchor then commit as one
## transaction, cancellation on tool switch, Test-mode refusal, and the frozen
## brush metadata carried by the recorded stroke.
##   godot --headless --path . -s res://tests/milestone/placement_tools.gd
const BrushScript := preload("res://scripts/sim/brush.gd")
const Geometry := preload("res://scripts/discovery/edit_geometry.gd")
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
	root.get_node("TimeController").set_process_unhandled_input(false)
	var lab = load("res://tests/milestone/paint_tools_lab.gd").new()
	root.add_child(lab)
	await process_frame
	check(lab.tool_mode == "" and not lab.line_button.button_pressed and not lab.box_button.button_pressed, "editor starts in paint mode with both tool buttons up")
	key(lab, KEY_L)
	check(lab.tool_mode == "line" and lab.line_button.button_pressed and not lab.box_button.button_pressed, "L enters line mode and presses its button")
	key(lab, KEY_K)
	check(lab.tool_mode == "box" and lab.box_button.button_pressed and not lab.line_button.button_pressed, "K switches to box mode and releases the line button")
	key(lab, KEY_K)
	check(lab.tool_mode == "" and not lab.box_button.button_pressed, "K again returns to paint mode")
	lab.line_button.button_pressed = true
	check(lab.tool_mode == "line", "the Line button enters line mode")
	# Line: anchor, then commit one stroke along the connected path with the frozen brush.
	lab._choose_material(Elements.Id.WALL)
	lab.radius_input.value = 1
	var a := Vector3i(10, 12, 64)
	var b := Vector3i(20, 15, 64)
	lab._tool_click(a)
	check(lab.tool_anchor == a and lab.sim.records.is_empty(), "first click anchors without recording")
	lab._tool_click(Vector3i(-1, -1, -1))
	check(lab.tool_anchor == a, "an invalid target does not disturb the anchor")
	lab._tool_click(b)
	check(lab.tool_anchor.x < 0 and lab.sim.records.size() == 1 and lab.sim.transactions == 1, "second click opens one transaction, records exactly one stroke and clears the anchor")
	lab.capturing = false # the fake never completes its capture callback
	var record: Array = lab.sim.records[0]
	check(record[1] == Geometry.stroke(a, b) and record[2] == 1 and record[3] == Elements.Id.WALL and record[6] == BrushScript.Shape.CUBE and record[7] == lab.axis,
		"the line stroke follows the face-connected path with the frozen radius, material, cube shape and plane axis")
	check(lab.tool_mode == "line" and lab.active_transaction < 0, "line mode stays active after a commit and the transaction is closed")
	# Box: two corners in either order fill the half-open box with the current material.
	key(lab, KEY_K)
	lab._choose_material(Elements.Id.SAND)
	lab.capturing = true
	lab._tool_click(Vector3i(30, 40, 50))
	lab._tool_click(Vector3i(25, 44, 48))
	check(lab.tool_anchor == Vector3i(30, 40, 50) and lab.sim.regions.is_empty() and not lab.edit_message.is_empty(), "a commit while the previous edit is still capturing keeps the anchor and explains")
	lab.capturing = false
	lab._tool_click(Vector3i(25, 44, 48))
	check(lab.sim.regions.size() == 1 and lab.sim.regions[0][1] == Vector3i(25, 40, 48) and lab.sim.regions[0][2] == Vector3i(31, 45, 51) and lab.sim.regions[0][3] == Elements.Id.SAND and lab.sim.transactions == 2,
		"box commit records the half-open box between the two corners with the current material as its own transaction")
	lab.capturing = false
	check(lab.sim.records.size() == 1, "the box tool records no brush stroke")
	# Switching tools drops a pending anchor; material changes keep the tool.
	lab._tool_click(Vector3i(5, 5, 5))
	key(lab, KEY_L)
	check(lab.tool_mode == "line" and lab.tool_anchor.x < 0, "switching tools drops the pending anchor")
	lab._tool_click(Vector3i(5, 5, 5))
	lab._choose_material(Elements.Id.WATER)
	check(lab.tool_mode == "line" and lab.tool_anchor == Vector3i(5, 5, 5), "choosing a material keeps the tool and its anchor")
	key(lab, KEY_L)
	# Test mode refuses the tools with a message and records nothing.
	key(lab, KEY_K)
	lab.testing = true
	lab._tool_click(Vector3i(1, 1, 1))
	lab._tool_click(Vector3i(3, 3, 3))
	check(lab.tool_anchor.x < 0 and lab.sim.regions.size() == 1 and not lab.edit_message.is_empty(), "Test mode refuses two-click tools with a message")
	lab.testing = false
	lab.queue_free()
	await process_frame
	print("Placement tools CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
