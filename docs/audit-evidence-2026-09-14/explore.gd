extends SceneTree
var sim: Node3D
var tc: Node
var rig: Node3D
var brush: Node3D
const OUT = "/tmp/powder-audit-20260914/"
func _initialize():
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP,true)
	call_deferred("run")
func settle(n=30):
	for i in n:
		await process_frame
func shot(label):
	await settle(2)
	root.get_texture().get_image().save_png(OUT + label + ".png")
func measure(label, paint=false):
	await settle(45)
	var samples: Array[float] = []
	var start = Time.get_ticks_usec()
	var prev = start
	var tick0 = tc.tick
	for i in 180:
		if paint:
			sim.paint(Vector3i(VoxelCodec.GRID / 2 + (i % 30), VoxelCodec.GRID * 3 / 4, VoxelCodec.GRID / 2), 4, Elements.Id.SAND)
		await process_frame
		var now = Time.get_ticks_usec()
		samples.append((now-prev)/1000.0)
		prev = now
	var seconds = (prev-start)/1000000.0
	samples.sort()
	print(JSON.stringify({"case":label,"grid":VoxelCodec.GRID,"size":str(root.size),"scale":root.scaling_3d_scale,"mean_ms":seconds*1000/180,"p50_ms":samples[90],"p95_ms":samples[171],"p99_ms":samples[178],"fps":180/seconds,"tps":(tc.tick-tick0)/seconds}))
func key(code):
	var e=InputEventKey.new()
	e.keycode=code
	e.pressed=true
	root.push_input(e)
	e=InputEventKey.new()
	e.keycode=code
	e.pressed=false
	root.push_input(e)
func pointer(pos, pressed, motion=false):
	if motion:
		var m=InputEventMouseMotion.new()
		m.position=pos
		m.global_position=pos
		root.push_input(m)
	else:
		var e=InputEventMouseButton.new()
		e.position=pos
		e.global_position=pos
		e.button_index=MOUSE_BUTTON_LEFT
		e.pressed=pressed
		root.push_input(e)
func run():
	change_scene_to_file("res://scenes/main.tscn")
	await settle(4)
	sim=current_scene.get_node("SimVolume")
	tc=root.get_node("TimeController")
	rig=current_scene.get_node("CameraRig")
	brush=current_scene.get_node("Brush")
	print("CONFIG ", root.size, " viewport=",root.get_visible_rect(), " vsync=",DisplayServer.window_get_vsync_mode())
	await measure("demo_default_running")
	await shot("demo_later")
	tc.paused=true
	await measure("demo_default_paused")
	rig.frame_position=Vector3(0.85,0.65,0.85)*rig.world_size
	rig.frame_box(false)
	await measure("demo_close_paused")
	await shot("demo_close_paused")
	tc.paused=false
	await measure("demo_close_running")
	await shot("demo_close_running")
	await measure("demo_close_painting",true)
	tc.paused=true
	await measure("demo_close_paused_painting",true)
	# Actual viewport key dispatch, no direct handler calls.
	brush.element=Elements.Id.SAND
	tc.time_scale=0.5
	tc.paused=true
	key(KEY_1)
	await settle(2)
	print("INPUT key1 element=",brush.element," paused=",tc.paused," scale=",tc.time_scale)
	key(KEY_0)
	await settle(2)
	key(KEY_SPACE)
	await settle(2)
	print("INPUT zero_then_space paused=",tc.paused," scale=",tc.time_scale," frozen=",tc.is_frozen())
	# Press in canvas; drag to toolbar; release there.
	pointer(Vector2(800,450),false,true)
	pointer(Vector2(800,450),true)
	await settle(2)
	print("INPUT canvas_press painting=",brush._painting)
	pointer(Vector2(800,30),false,true)
	pointer(Vector2(800,30),false)
	await settle(2)
	print("INPUT toolbar_release painting=",brush._painting)
	pointer(Vector2(800,450),false,true)
	await settle(2)
	print("INPUT return_canvas painting=",brush._painting)
	pointer(Vector2(800,450),false)
	# Freeze/reset evidence, then capture selected presets.
	tc.time_scale=1.0
	tc.effective_scale=1.0
	for scenario in ["Dam break","Forest fire","U-bend","Oil spill"]:
		sim.load_scenario(scenario)
		tc.paused=false
		await measure(scenario.to_lower().replace(" ","_")+"_close_running")
		await shot(scenario.to_lower().replace(" ","_"))
	quit()
