extends Node3D
## Procedural soundscape. Everything is synthesised at runtime from noise
## (no audio assets): a wind bed, and positional water, fire and steam beds
## whose loudness follows how much of each element is active in the world.
## Activity comes from the sim's per-frame tallies (splat_emit.glsl), fetched
## with a non-stalling readback a few times per second, and each emitter sits
## at the centroid of its element. Pitch follows the time scale and the
## element beds fade out when time is frozen, so nothing pops on pause.

const MIX_RATE := 16000.0
## Seconds between activity readbacks.
const POLL_INTERVAL := 0.12
## Activity at which each bed reaches full loudness, as a fraction of the
## world's cells (so a 256^3 world needs eight times the cells of a 128^3 one).
const FULL_WATER := 0.003
const FULL_FIRE := 0.001
const FULL_STEAM := 0.004

@export var master_db := -6.0
@export var wind_db := -20.0
@export var water_db := -8.0
@export var fire_db := -6.0
@export var steam_db := -12.0
@export var muted := false

var _sim: Node3D
var _grid := 128.0
var _poll := 0.0
var _rng := RandomNumberGenerator.new()

# One synth per bed: player, playback, state and smoothed gain.
var _beds: Dictionary = {}


class Bed:
	var player: Node  # AudioStreamPlayer or AudioStreamPlayer3D
	var playback: AudioStreamGeneratorPlayback
	var gain := 0.0
	var target := 0.0
	var lp1 := 0.0
	var lp2 := 0.0
	var hp_prev_in := 0.0
	var hp_prev_out := 0.0
	var phase := 0.0
	var burst := 0.0
	var burst_freq := 0.0
	var crackle := 0.0
	var lfo := 0.0
	var position := Vector3.ZERO
	var base_db := 0.0


func _ready() -> void:
	_rng.seed = 1234
	_sim = get_tree().get_first_node_in_group("sim")
	if _sim == null:
		_sim = get_node_or_null("../SimVolume")
	if _sim and "GRID" in _sim:
		_grid = float(_sim.GRID)
	_beds["wind"] = _make_bed(false, wind_db)
	_beds["water"] = _make_bed(true, water_db)
	_beds["fire"] = _make_bed(true, fire_db)
	_beds["steam"] = _make_bed(true, steam_db)
	_beds["wind"].target = 1.0
	if _sim and _sim.has_signal("activity_ready"):
		_sim.activity_ready.connect(_on_activity)
	for arg in OS.get_cmdline_user_args():
		if arg == "audio=0":
			muted = true


func _make_bed(positional: bool, db: float) -> Bed:
	var bed := Bed.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = 0.15
	if positional:
		var p3 := AudioStreamPlayer3D.new()
		p3.stream = gen
		p3.unit_size = 1.0 * (_sim.world_size() if _sim else 1.0)
		p3.max_db = 3.0
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
		p3.volume_db = -80.0
		add_child(p3)
		bed.player = p3
	else:
		var p := AudioStreamPlayer.new()
		p.stream = gen
		p.volume_db = -80.0
		add_child(p)
		bed.player = p
	bed.base_db = db
	bed.player.autoplay = true
	bed.player.play()
	bed.playback = bed.player.get_stream_playback()
	return bed


func _on_activity(counts: PackedInt32Array) -> void:
	if counts.size() < 21:
		return
	_set_activity("water", counts, 8, FULL_WATER)
	_set_activity("fire", counts, 12, FULL_FIRE)
	_set_activity("steam", counts, 16, FULL_STEAM)


func _set_activity(name: String, counts: PackedInt32Array, base: int, full: float) -> void:
	var bed: Bed = _beds[name]
	var n := counts[base]
	# Loudness grows with the log of the active volume, like a crowd.
	var cells := full * _grid * _grid * _grid
	bed.target = clampf(log(1.0 + n) / log(1.0 + cells), 0.0, 1.0)
	if n > 0 and _sim:
		var c := Vector3(counts[base + 1], counts[base + 2], counts[base + 3]) / float(n)
		var model := c / _grid - Vector3(0.5, 0.5, 0.5)
		bed.position = _sim.global_transform * model


func _process(delta: float) -> void:
	_poll -= delta
	if _poll <= 0.0 and _sim and _sim.has_method("request_activity"):
		_poll = POLL_INTERVAL
		_sim.request_activity()
	var frozen: bool = TimeController.is_frozen()
	var scale: float = TimeController.effective_scale
	var pitch := clampf(pow(maxf(scale, 0.05), 0.5), 0.5, 1.6)
	for name in _beds:
		var bed: Bed = _beds[name]
		var target := bed.target
		if name != "wind" and frozen:
			target = 0.0
		# Fast attack, slow release; the freeze fade is the release.
		var rate := 8.0 if target > bed.gain else 2.5
		bed.gain = lerpf(bed.gain, target, 1.0 - exp(-rate * delta))
		var db := master_db + bed.base_db + linear_to_db(maxf(bed.gain, 0.0005))
		bed.player.volume_db = -80.0 if muted else db
		if bed.player is AudioStreamPlayer3D:
			bed.player.pitch_scale = pitch
			bed.player.global_position = bed.player.global_position.lerp(bed.position, 1.0 - exp(-4.0 * delta))
		if bed.playback == null:
			if bed.player.playing:
				bed.playback = bed.player.get_stream_playback()
			continue
		_fill(name, bed)


## Synthesise as many frames as the generator will take.
func _fill(name: String, bed: Bed) -> void:
	var frames := bed.playback.get_frames_available()
	if frames <= 0:
		return
	var buf := PackedVector2Array()
	buf.resize(frames)
	var dt := 1.0 / MIX_RATE
	match name:
		"wind":
			_synth_wind(bed, buf, frames, dt)
		"water":
			_synth_water(bed, buf, frames, dt)
		"fire":
			_synth_fire(bed, buf, frames, dt)
		"steam":
			_synth_steam(bed, buf, frames, dt)
	bed.playback.push_buffer(buf)


func _noise() -> float:
	return _rng.randf() * 2.0 - 1.0


## Two cascaded one-pole low-passes over white noise, with a slow gust LFO
## moving both the cutoff and the level.
func _synth_wind(bed: Bed, buf: PackedVector2Array, frames: int, dt: float) -> void:
	for i in frames:
		bed.lfo += dt * 0.11
		var gust := 0.55 + 0.45 * sin(bed.lfo * TAU) * sin(bed.lfo * TAU * 0.37 + 1.3)
		var k := 0.012 + 0.03 * gust
		bed.lp1 += (_noise() - bed.lp1) * k
		bed.lp2 += (bed.lp1 - bed.lp2) * k
		var s := bed.lp2 * 9.0 * (0.6 + 0.4 * gust)
		buf[i] = Vector2(s, s)


## Band-limited hiss for the sheet of water plus occasional bubble chirps.
func _synth_water(bed: Bed, buf: PackedVector2Array, frames: int, dt: float) -> void:
	for i in frames:
		var n := _noise()
		bed.lp1 += (n - bed.lp1) * 0.35
		var hp := bed.lp1 - bed.hp_prev_in + 0.985 * bed.hp_prev_out
		bed.hp_prev_in = bed.lp1
		bed.hp_prev_out = hp
		if bed.burst <= 0.0 and _rng.randf() < 0.0006 * (0.3 + bed.gain):
			bed.burst = 1.0
			bed.burst_freq = _rng.randf_range(250.0, 900.0)
			bed.phase = 0.0
		var bubble := 0.0
		if bed.burst > 0.0:
			bed.phase += dt * bed.burst_freq * (1.0 + 0.6 * (1.0 - bed.burst))
			bubble = sin(bed.phase * TAU) * bed.burst * bed.burst * 0.5
			bed.burst -= dt * 18.0
		var s := hp * 1.6 + bubble
		buf[i] = Vector2(s, s)


## Low roar plus sparse crackles: random impulses through a fast-decaying
## envelope of noise.
func _synth_fire(bed: Bed, buf: PackedVector2Array, frames: int, dt: float) -> void:
	for i in frames:
		var n := _noise()
		bed.lp1 += (n - bed.lp1) * 0.05
		bed.lp2 += (bed.lp1 - bed.lp2) * 0.05
		var roar := bed.lp2 * 5.0
		if _rng.randf() < 0.0012 * (0.4 + bed.gain):
			bed.crackle = _rng.randf_range(0.4, 1.0)
		var crackle := n * bed.crackle * bed.crackle
		bed.crackle = maxf(bed.crackle - dt * 60.0, 0.0)
		var s := roar + crackle * 0.9
		buf[i] = Vector2(s, s)


## High-passed hiss with a gentle flutter.
func _synth_steam(bed: Bed, buf: PackedVector2Array, frames: int, dt: float) -> void:
	for i in frames:
		var n := _noise()
		var hp := n - bed.hp_prev_in + 0.6 * bed.hp_prev_out
		bed.hp_prev_in = n
		bed.hp_prev_out = hp
		bed.lfo += dt * 3.1
		var flutter := 0.8 + 0.2 * sin(bed.lfo * TAU)
		var s := hp * 0.5 * flutter
		buf[i] = Vector2(s, s)
