extends SceneTree
## Diagnostic: liquid mass over ticks with hydro and thermal toggled
## independently, on the water-levels fixture. Prints one line per variant.
##   godot --path . --always-on-top --disable-vsync -s res://tests/milestone/thermal_mass_probe.gd -- grid=128
var sim: Node3D

func _initialize() -> void:
	create_timer(110.0).timeout.connect(func():
		push_error("mass probe watchdog")
		quit(1))
	root.get_node("TimeController").paused = true
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	root.add_child(sim)
	call_deferred("_run")

func world() -> PackedByteArray:
	var data := WorldBuilder.empty()
	WorldBuilder.fill_box(data, Vector3i(4, 0, 4), Vector3i(44, 30, 44), Elements.Id.WALL)
	WorldBuilder.fill_box(data, Vector3i(6, 6, 6), Vector3i(42, 30, 42), Elements.Id.AIR)
	WorldBuilder.fill_box(data, Vector3i(10, 60, 10), Vector3i(34, 84, 34), Elements.Id.WATER)
	return data.to_byte_array()

func run_ticks(ticks: int) -> PackedByteArray:
	var remaining := ticks
	while remaining > 0:
		var batch := mini(remaining, 100)
		sim.request_ticks(batch)
		remaining -= batch
		await process_frame
		sim.request_layer_counts()
		await sim.layer_counts_ready
	await process_frame
	sim.request_readback(func(_b): pass)
	return await sim.readback_ready

func _run() -> void:
	for i in 4:
		await process_frame
	var base := world()
	var before: int = sim.mass(base, Elements.Id.WATER)
	var results := {}
	for variant in [
			{"name": "flags3 hydro air", "flags": 3, "hydro": true, "air": true},
			{"name": "flags3 hydro air (again)", "flags": 3, "hydro": true, "air": true},
			{"name": "flags3|16 (no thermal) hydro air", "flags": 3 | 16, "hydro": true, "air": true},
			{"name": "flags3|16 (no thermal) hydro air (again)", "flags": 3 | 16, "hydro": true, "air": true},
			{"name": "flags3 no-hydro no-air", "flags": 3, "hydro": false, "air": false},
			{"name": "flags3|16 no-hydro no-air", "flags": 3 | 16, "hydro": false, "air": false}]:
		sim.rule_flags = variant.flags
		sim.hydro_enabled = variant.hydro
		sim.air_enabled = variant.air
		sim.upload(base)
		await process_frame
		var after := await run_ticks(300)
		var mass: int = sim.mass(after, Elements.Id.WATER)
		var hist: PackedInt64Array = sim.histogram(after)
		print("MASS %s: %d -> %d (delta %d) water cells %d steam %d ice %d" % [variant.name, before, mass, mass - before, hist[Elements.Id.WATER], hist[Elements.Id.STEAM], hist[Elements.Id.ICE]])
		results[variant.name] = after
	print("BYTES same run twice, thermal on: %s" % ("identical" if results["flags3 hydro air"] == results["flags3 hydro air (again)"] else "DIFFERENT"))
	print("BYTES same run twice, thermal off: %s" % ("identical" if results["flags3|16 (no thermal) hydro air"] == results["flags3|16 (no thermal) hydro air (again)"] else "DIFFERENT"))
	print("BYTES thermal on vs off (hydro, air): %s" % ("identical" if results["flags3 hydro air"] == results["flags3|16 (no thermal) hydro air"] else "DIFFERENT"))
	print("BYTES thermal on vs off (no hydro, no air): %s" % ("identical" if results["flags3 no-hydro no-air"] == results["flags3|16 no-hydro no-air"] else "DIFFERENT"))
	sim.queue_free()
	for i in 3:
		await process_frame
	quit(0)
