extends SceneTree
## Lattice ripple on smoothed powder slopes: A/B against the immutable pre-fix
## opaque shader. Frozen bytes, fixed cameras, neutralized textures/grain so the
## only per-pixel variation is shading shape (normal, curvature, AO).
## godot --path . --always-on-top --disable-vsync -s res://tests/milestone/render_powder_ripple_gpu.gd -- grid=128
const BASELINE := preload("res://tests/milestone/fixtures/voxel_opaque_ripple_baseline.gdshader")
const FIXED := preload("res://shaders/spatial/voxel_opaque.gdshader")
const STEP := 0.05 # cells along x between samples: 20 samples per lattice cell
var sim: Node3D
var camera: Camera3D
var stage: Node3D
var failures := 0
var checks := 0
var rows: Array[Dictionary] = []
var out_dir := "res://docs/milestone/powder-ripple-evidence/gpu"

func _initialize() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("output_dir="):
			out_dir = argument.trim_prefix("output_dir=")
	create_timer(170).timeout.connect(func(): push_error("Powder ripple timeout"); quit(2))
	call_deferred("_run")

func _run() -> void:
	root.get_node("TimeController").paused = true
	root.size = Vector2i(1200, 900)
	root.scaling_3d_scale = 1.0
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	stage = Node3D.new()
	root.add_child(stage)
	sim = load("res://scenes/sim_volume.tscn").instantiate()
	sim.listen_to_time_controller = false
	sim.current_scenario = "Empty"
	sim.fx_enabled = false
	stage.add_child(sim)
	sim.get_node("VolumeMesh").visible = false # solid fixtures only
	camera = Camera3D.new()
	camera.near = 0.001
	camera.fov = 50.0
	stage.add_child(camera)
	var world := WorldEnvironment.new()
	world.environment = Environment.new()
	world.environment.background_mode = Environment.BG_COLOR
	world.environment.background_color = Color.BLACK
	world.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world.environment.ambient_light_color = Color.WHITE
	world.environment.ambient_light_energy = 0.25
	world.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	var to_sun := Vector3(0.4, 1.0, 0.3).normalized()
	sun.light_energy = 1.0
	sun.shadow_enabled = false
	stage.add_child(sun)
	sun.look_at_from_position(Vector3.ZERO, -to_sun, Vector3.UP)
	sim.set_param("light_dir", to_sun)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	for i in 30:
		await process_frame
	# Neutralize decorative texture and grain: constant triplanar texel, zero
	# grain. Curvature darkening and AO stay at full strength (detail 1.0).
	sim.set_param("texture_tile", 100000.0)
	sim.set_param("mat_grain", PackedFloat32Array([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]))
	sim.set_param("detail_strength", 1.0)
	sim.set_param("ao_strength", 1.0)
	var s := float(VoxelCodec.GRID) / 128.0
	var cases: Array[Dictionary] = [
		{"name": "sand-shallow", "id": Elements.Id.SAND, "slope": 0.35, "control": false},
		{"name": "sand-repose", "id": Elements.Id.SAND, "slope": 0.6, "control": false},
		{"name": "wall-repose", "id": Elements.Id.WALL, "slope": 0.6, "control": true},
	]
	for c in cases:
		var bytes := _wedge(c.id, c.slope)
		sim.upload(bytes)
		var centre := _world(Vector3(64.0 * s, 30.0 * s, 64.0 * s))
		camera.position = _world(Vector3(150.0 * s, 96.0 * s, 150.0 * s))
		camera.look_at(centre, Vector3.UP)
		var images := {}
		for variant in ["baseline", "fixed"]:
			var mat: ShaderMaterial = sim.get_node("Mesh").material_override
			mat.shader = BASELINE if variant == "baseline" else FIXED
			for mode in [0, 8]:
				sim.set_param("debug_mode", mode)
				for i in 12:
					await process_frame
				await RenderingServer.frame_post_draw
				var img := root.get_texture().get_image()
				images[variant + str(mode)] = img
				_check(img.save_png(out_dir + "/%s-%s-%s.png" % [c.name, variant, "lit" if mode == 0 else "normals"]) == OK, "capture %s %s mode %d" % [c.name, variant, mode])
			var row := _measure(images[variant + "0"], images[variant + "8"], c.slope)
			row["variant"] = variant
			row["case"] = c.name
			rows.append(row)
			print(JSON.stringify(row))
		var b: Dictionary = rows[rows.size() - 2]
		var f: Dictionary = rows[rows.size() - 1]
		_check(b.samples > 2000 and f.samples == b.samples, c.name + " samples the same substantial visible slope band")
		if c.control:
			# Recapture the baseline lit image to measure frame-to-frame self-noise.
			var mat2: ShaderMaterial = sim.get_node("Mesh").material_override
			mat2.shader = BASELINE
			sim.set_param("debug_mode", 0)
			for i in 12:
				await process_frame
			await RenderingServer.frame_post_draw
			var again := root.get_texture().get_image()
			var self_diff := _diff(images["baseline0"], again)
			var ab_diff := _diff(images["baseline0"], images["fixed0"])
			var n_diff := _diff(images["baseline8"], images["fixed8"])
			var diag := {"case": c.name, "self_changed_bytes": self_diff.changed, "self_max_delta": self_diff.max_delta, "ab_changed_bytes": ab_diff.changed, "ab_max_delta": ab_diff.max_delta, "normals_changed_bytes": n_diff.changed, "normals_max_delta": n_diff.max_delta}
			rows.append(diag)
			print(JSON.stringify(diag))
			_check(n_diff.changed == 0, c.name + " normal control image is byte-identical")
			_check(ab_diff.max_delta <= 1 and ab_diff.changed <= maxi(self_diff.changed * 2, 64), c.name + " lit control differs by at most one 8-bit step in no more pixels than self-noise allows")
		else:
			_check(b.luminance_ripple_rms > 0.012, c.name + " baseline reproduces visible lattice ripple (rms > 1.2% of mean)")
			_check(f.luminance_ripple_rms <= 0.5 * b.luminance_ripple_rms, c.name + " fixed lit ripple at most half of baseline")
			_check(f.normal_ripple_rms_deg <= 0.5 * b.normal_ripple_rms_deg, c.name + " fixed normal ripple at most half of baseline")
			_check(absf(f.mean_luminance - b.mean_luminance) < 0.08 * b.mean_luminance, c.name + " mean brightness preserved within 8%")
		var after: PackedByteArray = await _read()
		_check(after == bytes, c.name + " GPU physical bytes unchanged across all captures")
	# Reviewer concern 1: the level-2 stencil reaches four cells, so sand near a
	# vertical wall face could take a systematic tilt. A sand slope piled against
	# a full-height wall; normals sampled by distance from the wall face.
	var against := _wedge_against_wall(0.6)
	sim.upload(against)
	camera.position = _world(Vector3(150.0 * s, 96.0 * s, 150.0 * s))
	camera.look_at(_world(Vector3(64.0 * s, 30.0 * s, 64.0 * s)), Vector3.UP)
	var tilt := {}
	for variant in ["baseline", "fixed"]:
		var mat: ShaderMaterial = sim.get_node("Mesh").material_override
		mat.shader = BASELINE if variant == "baseline" else FIXED
		sim.set_param("debug_mode", 8)
		for i in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		_check(img.save_png(out_dir + "/sand-against-wall-" + variant + "-normals.png") == OK, "capture wall-adjacent " + variant)
		tilt[variant] = _wall_tilt(img, 0.6)
		print(JSON.stringify({"case": "sand-against-wall", "variant": variant, "tilt_by_distance": tilt[variant]}))
	rows.append({"case": "sand-against-wall", "baseline": tilt.baseline, "fixed": tilt.fixed})
	var worst := 0.0
	for bin in tilt.fixed:
		worst = maxf(worst, absf(tilt.fixed[bin].mean_signed_deg - tilt.baseline[bin].mean_signed_deg))
	rows.append({"case": "sand-against-wall-summary", "max_mean_tilt_change_deg": worst})
	print(JSON.stringify(rows[-1]))
	_check(await _read() == against, "wall-adjacent sand GPU physical bytes unchanged")
	# Reviewer concern 2: wood and plant are smoothed too. Matched before/after
	# captures with pixel statistics; no ripple gate, only exact bytes.
	for spec in [{"name": "wood-plank", "bytes": _plank()}, {"name": "plant-sphere", "bytes": _plant()}]:
		sim.upload(spec.bytes)
		camera.position = _world(Vector3(120.0 * s, 70.0 * s, 130.0 * s))
		camera.look_at(_world(Vector3(64.0 * s, 20.0 * s, 64.0 * s)), Vector3.UP)
		var shots := {}
		for variant in ["baseline", "fixed"]:
			var mat: ShaderMaterial = sim.get_node("Mesh").material_override
			mat.shader = BASELINE if variant == "baseline" else FIXED
			for mode in [0, 8]:
				sim.set_param("debug_mode", mode)
				for i in 12:
					await process_frame
				await RenderingServer.frame_post_draw
				var img := root.get_texture().get_image()
				shots[variant + str(mode)] = img
				_check(img.save_png(out_dir + "/%s-%s-%s.png" % [spec.name, variant, "lit" if mode == 0 else "normals"]) == OK, "capture " + spec.name + " " + variant)
		var stat := _material_diff(shots["baseline0"], shots["fixed0"], shots["baseline8"], shots["fixed8"])
		stat["case"] = spec.name
		rows.append(stat)
		print(JSON.stringify(stat))
		_check(await _read() == spec.bytes, spec.name + " GPU physical bytes unchanged")
	# Visual reference: a heap cone, captured only (no ripple gate: radial lines cross ridges).
	var cone := _cone()
	sim.upload(cone)
	camera.position = _world(Vector3(140.0 * s, 90.0 * s, 150.0 * s))
	camera.look_at(_world(Vector3(64.0 * s, 24.0 * s, 64.0 * s)), Vector3.UP)
	sim.set_param("debug_mode", 0)
	for variant in ["baseline", "fixed"]:
		var mat: ShaderMaterial = sim.get_node("Mesh").material_override
		mat.shader = BASELINE if variant == "baseline" else FIXED
		for i in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		_check(root.get_texture().get_image().save_png(out_dir + "/cone-" + variant + "-lit.png") == OK, "capture cone " + variant)
	_check(await _read() == cone, "cone GPU physical bytes unchanged")
	var report := FileAccess.open(out_dir + "/ripple-metrics.json", FileAccess.WRITE)
	report.store_string(JSON.stringify(rows, "\t"))
	report.close()
	print("POWDER_RIPPLE_CHECKS %d FAILURES %d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func _height(slope: float, x: float) -> float:
	var s := float(VoxelCodec.GRID) / 128.0
	return 56.0 * s - slope * (x - 8.0 * s)

func _wedge(id: int, slope: float) -> PackedByteArray:
	var s := float(VoxelCodec.GRID) / 128.0
	var d := WorldBuilder.empty()
	var n := VoxelCodec.GRID
	for z in range(int(8 * s), int(120 * s)):
		for x in range(int(8 * s), int(120 * s)):
			var h := int(floor(_height(slope, float(x))))
			for y in range(0, mini(h, n)):
				d[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(id, WorldBuilder.seed_at(x, y, z))
	return d.to_byte_array()

func _cone() -> PackedByteArray:
	var s := float(VoxelCodec.GRID) / 128.0
	var d := WorldBuilder.empty()
	WorldBuilder.fill_box(d, Vector3i(0, 0, 0), Vector3i(VoxelCodec.GRID, int(4 * s), VoxelCodec.GRID), Elements.Id.WALL)
	for y in range(int(4 * s), int(52 * s)):
		var radius := (52.0 * s - y) * 0.9
		for z in range(int(16 * s), int(112 * s)):
			for x in range(int(16 * s), int(112 * s)):
				if Vector2(x - 64 * s, z - 64 * s).length() < radius:
					d[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.SAND, WorldBuilder.seed_at(x, y, z))
	return d.to_byte_array()

func _world(cell: Vector3) -> Vector3:
	return (cell / float(VoxelCodec.GRID) - Vector3.ONE * 0.5) * sim.world_size()

func _residual_rms(values: Array[float], window: int) -> Dictionary:
	var half := window / 2
	var residual: Array[float] = []
	for i in range(half, values.size() - half):
		var sum := 0.0
		for j in range(i - half, i + half + 1):
			sum += values[j]
		residual.append(values[i] - sum / float(2 * half + 1))
	if residual.is_empty():
		return {"rms": 0.0, "peak_to_peak": 0.0}
	var sq := 0.0
	var lo := residual[0]
	var hi := residual[0]
	for r in residual:
		sq += r * r
		lo = minf(lo, r)
		hi = maxf(hi, r)
	return {"rms": sqrt(sq / residual.size()), "peak_to_peak": hi - lo}

func _measure(lit: Image, normals: Image, slope: float) -> Dictionary:
	var s := float(VoxelCodec.GRID) / 128.0
	var ideal := Vector3(slope, 1.0, 0.0).normalized()
	var window := int(round((1.0 / STEP) / slope)) # one riser spacing
	var x_lo := 8.0 * s + 14.0 * s / slope
	var x_hi := minf(8.0 * s + 44.0 * s / slope, 116.0 * s)
	var count := int((x_hi - x_lo) / STEP)
	var lum_sum := 0.0
	var samples := 0
	var lum_ripple_sq := 0.0
	var lum_p2p := 0.0
	var ang_ripple_sq := 0.0
	var ang_p2p := 0.0
	var lines := 0
	for z in [28.0, 48.0, 64.0, 80.0, 100.0]:
		var lums: Array[float] = []
		var angs: Array[float] = []
		for i in count:
			var x := x_lo + i * STEP
			var p := Vector3(x, _height(slope, x), z * s)
			var pos := camera.unproject_position(_world(p))
			var pixel := Vector2i(pos.floor())
			if pixel.x < 2 or pixel.y < 2 or pixel.x >= lit.get_width() - 2 or pixel.y >= lit.get_height() - 2:
				continue
			var col := lit.get_pixelv(pixel).srgb_to_linear()
			var l := 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b
			var nc := normals.get_pixelv(pixel).srgb_to_linear()
			var n := (Vector3(nc.r, nc.g, nc.b) * 2.0 - Vector3.ONE).normalized()
			if l < 0.01 or maxf(nc.r, maxf(nc.g, nc.b)) < 0.1:
				continue # missing surface; not part of the ripple statistic
			lums.append(l)
			angs.append(rad_to_deg(atan2(n.x, n.y) - atan2(ideal.x, ideal.y)))
			lum_sum += l
			samples += 1
		if lums.size() <= window + 2:
			continue
		lines += 1
		var lr := _residual_rms(lums, window)
		var ar := _residual_rms(angs, window)
		lum_ripple_sq += lr.rms * lr.rms
		lum_p2p = maxf(lum_p2p, lr.peak_to_peak)
		ang_ripple_sq += ar.rms * ar.rms
		ang_p2p = maxf(ang_p2p, ar.peak_to_peak)
	var mean := lum_sum / maxf(samples, 1)
	var lum_rms := sqrt(lum_ripple_sq / maxf(lines, 1))
	return {"samples": samples, "lines": lines, "window_cells": window * STEP, "mean_luminance": mean,
		"luminance_ripple_rms": lum_rms / maxf(mean, 1e-6), "luminance_ripple_peak_to_peak": lum_p2p / maxf(mean, 1e-6),
		"normal_ripple_rms_deg": sqrt(ang_ripple_sq / maxf(lines, 1)), "normal_ripple_peak_to_peak_deg": ang_p2p}

func _wedge_against_wall(slope: float) -> PackedByteArray:
	var s := float(VoxelCodec.GRID) / 128.0
	var d := WorldBuilder.empty()
	var n := VoxelCodec.GRID
	# Full-height wall slab at x in [8, 12); sand slope descends from the wall face at x = 12.
	WorldBuilder.fill_box(d, Vector3i(int(8 * s), 0, int(8 * s)), Vector3i(int(12 * s), n, int(120 * s)), Elements.Id.WALL)
	for z in range(int(8 * s), int(120 * s)):
		for x in range(int(12 * s), int(120 * s)):
			var h := int(floor(60.0 * s - slope * (x - 12.0 * s)))
			for y in range(0, mini(h, n)):
				d[VoxelCodec.index(x, y, z)] = VoxelCodec.encode(Elements.Id.SAND, WorldBuilder.seed_at(x, y, z))
	return d.to_byte_array()

func _wall_tilt(normals: Image, slope: float) -> Dictionary:
	var s := float(VoxelCodec.GRID) / 128.0
	var ideal := Vector3(slope, 1.0, 0.0).normalized()
	var bins := {}
	for z in [28.0, 48.0, 64.0, 80.0, 100.0]:
		for i in 180:
			var dist := i * 0.05 # cells from the wall face, 0..9
			var x := 12.0 * s + dist
			var p := Vector3(x, 60.0 * s - slope * (x - 12.0 * s), z * s)
			var pos := camera.unproject_position(_world(p))
			var pixel := Vector2i(pos.floor())
			if pixel.x < 2 or pixel.y < 2 or pixel.x >= normals.get_width() - 2 or pixel.y >= normals.get_height() - 2:
				continue
			var nc := normals.get_pixelv(pixel).srgb_to_linear()
			if maxf(nc.r, maxf(nc.g, nc.b)) < 0.1:
				continue
			var nv := (Vector3(nc.r, nc.g, nc.b) * 2.0 - Vector3.ONE).normalized()
			var key := str(int(floor(dist)))
			if not bins.has(key):
				bins[key] = {"count": 0, "sum_signed": 0.0, "sum_abs": 0.0, "max_abs": 0.0}
			var signed := rad_to_deg(atan2(nv.x, nv.y) - atan2(ideal.x, ideal.y))
			bins[key].count += 1
			bins[key].sum_signed += signed
			bins[key].sum_abs += absf(signed)
			bins[key].max_abs = maxf(bins[key].max_abs, absf(signed))
	var out := {}
	for key in bins:
		var b: Dictionary = bins[key]
		out[key] = {"samples": b.count, "mean_signed_deg": b.sum_signed / maxf(b.count, 1), "mean_abs_deg": b.sum_abs / maxf(b.count, 1), "max_abs_deg": b.max_abs}
	return out

func _plank() -> PackedByteArray:
	var s := float(VoxelCodec.GRID) / 128.0
	var d := WorldBuilder.empty()
	WorldBuilder.fill_box(d, Vector3i(0, 0, 0), Vector3i(VoxelCodec.GRID, int(4 * s), VoxelCodec.GRID), Elements.Id.WALL)
	# Two-cell-thick plank on posts, plus a one-cell-thick plank alongside.
	WorldBuilder.fill_box(d, Vector3i(int(24 * s), int(20 * s), int(40 * s)), Vector3i(int(104 * s), int(22 * s), int(60 * s)), Elements.Id.WOOD)
	WorldBuilder.fill_box(d, Vector3i(int(24 * s), int(20 * s), int(70 * s)), Vector3i(int(104 * s), int(21 * s), int(90 * s)), Elements.Id.WOOD)
	for x in [int(28 * s), int(100 * s)]:
		for z in [int(44 * s), int(56 * s), int(74 * s), int(86 * s)]:
			WorldBuilder.fill_box(d, Vector3i(x, int(4 * s), z), Vector3i(x + 1, int(20 * s), z + 1), Elements.Id.WOOD)
	return d.to_byte_array()

func _plant() -> PackedByteArray:
	var s := float(VoxelCodec.GRID) / 128.0
	var d := WorldBuilder.empty()
	WorldBuilder.fill_box(d, Vector3i(0, 0, 0), Vector3i(VoxelCodec.GRID, int(4 * s), VoxelCodec.GRID), Elements.Id.WALL)
	WorldBuilder.fill_sphere(d, Vector3(64, 22, 64) * s, 14 * s, Elements.Id.PLANT)
	return d.to_byte_array()

func _material_diff(lit_a: Image, lit_b: Image, n_a: Image, n_b: Image) -> Dictionary:
	var da := lit_a.get_data()
	var db := lit_b.get_data()
	var changed := 0
	var max_delta := 0
	var sum_a := 0.0
	var sum_b := 0.0
	for i in mini(da.size(), db.size()):
		var delta := absi(da[i] - db[i])
		if delta != 0:
			changed += 1
		max_delta = maxi(max_delta, delta)
		sum_a += da[i]
		sum_b += db[i]
	var ang_sum := 0.0
	var ang_max := 0.0
	var count := 0
	for y in range(0, n_a.get_height(), 2):
		for x in range(0, n_a.get_width(), 2):
			var ca := n_a.get_pixel(x, y).srgb_to_linear()
			var cb := n_b.get_pixel(x, y).srgb_to_linear()
			if maxf(ca.r, maxf(ca.g, ca.b)) < 0.1 or maxf(cb.r, maxf(cb.g, cb.b)) < 0.1:
				continue
			var va := (Vector3(ca.r, ca.g, ca.b) * 2.0 - Vector3.ONE).normalized()
			var vb := (Vector3(cb.r, cb.g, cb.b) * 2.0 - Vector3.ONE).normalized()
			var ang := rad_to_deg(acos(clampf(va.dot(vb), -1.0, 1.0)))
			ang_sum += ang
			ang_max = maxf(ang_max, ang)
			count += 1
	return {"lit_changed_bytes": changed, "lit_max_delta": max_delta, "lit_mean_byte_baseline": sum_a / maxf(da.size(), 1), "lit_mean_byte_fixed": sum_b / maxf(db.size(), 1), "normal_pixels": count, "normal_mean_change_deg": ang_sum / maxf(count, 1), "normal_max_change_deg": ang_max}

func _diff(a: Image, b: Image) -> Dictionary:
	var da := a.get_data()
	var db := b.get_data()
	var changed := 0
	var max_delta := 0
	for i in mini(da.size(), db.size()):
		var delta := absi(da[i] - db[i])
		if delta != 0:
			changed += 1
		max_delta = maxi(max_delta, delta)
	return {"changed": changed, "max_delta": max_delta}

func _read() -> PackedByteArray:
	var result: Array[PackedByteArray] = []
	sim.request_readback(func(bytes: PackedByteArray): result.append(bytes))
	var deadline := Time.get_ticks_msec() + 15000
	while result.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	_check(not result.is_empty(), "readback completes within 15 seconds")
	return PackedByteArray() if result.is_empty() else result[0]

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print(("ok: " if ok else "FAIL: ") + message)
