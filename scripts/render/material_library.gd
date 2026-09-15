class_name MaterialLibrary
extends RefCounted
## Procedural placeholder PBR textures for the voxel materials, built at boot
## so the pipeline is not gated on assets. Layer index = "mat" in Elements.
## Replace with CC0 textures (ambientCG) by loading images into the same arrays.

const SIZE := 256
const LAYERS := 7  # 0 stone, 1 sand, 2 plant, 3 generic, 4 wood, 5 ice, 6 glass
const LAYER_ICE := 5
const LAYER_GLASS := 6
## Per-element-id uniform array length in every spatial shader (`palette[32]`,
## `extinction[32]`, `mat_*[32]`). Elements.PALETTE_SIZE may lag behind; the
## unused tail uploads as zero either way.
const SHADER_SLOTS := 32
## Names of shader uniforms indexed by element id.
const PER_ID_UNIFORMS := ["palette", "extinction", "mat_layer", "mat_smooth", "mat_grain", "mat_rough"]

static var _albedo: Texture2DArray
static var _normal: Texture2DArray
static var _grain: NoiseTexture3D


static func apply(material: ShaderMaterial) -> void:
	if _albedo == null:
		_build()
	material.set_shader_parameter("albedo_maps", _albedo)
	material.set_shader_parameter("normal_maps", _normal)
	material.set_shader_parameter("grain_noise", _grain)
	material.set_shader_parameter("mat_layer", padded(Elements.material_layers()))
	material.set_shader_parameter("mat_smooth", padded(Elements.floats("smooth")))
	material.set_shader_parameter("mat_grain", padded(Elements.floats("grain")))
	material.set_shader_parameter("mat_rough", padded(Elements.floats("rough", 0.8)))
	material.set_shader_parameter("texture_size", float(SIZE))


## Extend a per-id array to SHADER_SLOTS entries; new entries are zero. A
## longer array is returned unchanged (the shader ignores the excess).
static func padded(values: Variant) -> Variant:
	if values is PackedColorArray or values is PackedFloat32Array or values is PackedInt32Array:
		if values.size() < SHADER_SLOTS:
			var out = values.duplicate()
			var first: int = out.size()
			out.resize(SHADER_SLOTS)
			# Resize fills colours with opaque black; unused ids must be fully zero.
			for i in range(first, SHADER_SLOTS):
				out[i] = Color(0, 0, 0, 0) if values is PackedColorArray else 0
			return out
	return values


static func _build() -> void:
	var albedos: Array[Image] = []
	var normals: Array[Image] = []
	# [frequency, octaves, contrast, bump strength] per layer
	var params := [
		[0.03, 5, 1.1, 2.5],   # stone: coarse, moderate relief
		[0.12, 3, 0.7, 2.0],   # sand: fine, low contrast
		[0.06, 4, 1.1, 3.0],   # plant
		[0.05, 4, 1.0, 3.0],   # generic
		[0.05, 4, 1.4, 3.5],   # wood: squashed into vertical grain below
		[0.04, 3, 0.45, 1.2],  # ice: pale, low contrast, faint cracks added below
		[0.02, 2, 0.15, 0.4],  # glass: near-white, almost featureless, very smooth
	]
	for i in LAYERS:
		var n := FastNoiseLite.new()
		n.seed = 100 + i
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = params[i][0]
		n.fractal_octaves = params[i][1]
		var height := n.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
		if i == 4:
			height = _streaks(height, 8)
		elif i == LAYER_ICE:
			height = _cracks(height, 0.35)
		elif i == LAYER_GLASS:
			height = _flatten(height, 0.9)
		var albedo := height.duplicate()
		albedo.convert(Image.FORMAT_RGB8)
		albedo.adjust_bcs(1.0, params[i][2], 1.0)
		albedo.generate_mipmaps()
		albedos.append(albedo)
		var normal := height.duplicate()
		normal.bump_map_to_normal_map(params[i][3])
		normal.convert(Image.FORMAT_RGB8)
		normal.generate_mipmaps()
		normals.append(normal)
	_albedo = Texture2DArray.new()
	_albedo.create_from_images(albedos)
	_normal = Texture2DArray.new()
	_normal.create_from_images(normals)

	var gn := FastNoiseLite.new()
	gn.seed = 7
	gn.noise_type = FastNoiseLite.TYPE_SIMPLEX
	gn.frequency = 0.25
	_grain = NoiseTexture3D.new()
	_grain.width = 32
	_grain.height = 32
	_grain.depth = 32
	_grain.seamless = true
	_grain.noise = gn


## Darken thin cellular edges into a seamless height map (ice cracks).
static func _cracks(src: Image, strength: float) -> Image:
	var n := FastNoiseLite.new()
	n.seed = 41
	n.noise_type = FastNoiseLite.TYPE_CELLULAR
	n.frequency = 0.035
	n.cellular_return_type = FastNoiseLite.RETURN_DISTANCE2_SUB
	var edges := n.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
	var out := src.duplicate()
	for y in SIZE:
		for x in SIZE:
			var e: float = edges.get_pixel(x, y).r # ~0 on a cell boundary, brighter inside
			var crack := 1.0 - smoothstep(0.0, 0.12, e)
			var h: Color = out.get_pixel(x, y)
			out.set_pixel(x, y, Color(h.r * (1.0 - strength * crack), h.g * (1.0 - strength * crack), h.b * (1.0 - strength * crack)))
	return out


## Pull a height map toward mid-grey so its albedo and normal stay almost flat.
static func _flatten(src: Image, amount: float) -> Image:
	var out := src.duplicate()
	for y in SIZE:
		for x in SIZE:
			var h: Color = out.get_pixel(x, y)
			var v := lerpf(h.r, 0.5, amount)
			out.set_pixel(x, y, Color(v, v, v))
	return out


## Squash a seamless image horizontally by `factor` and tile it back to size,
## giving grain that runs along Y (wood).
static func _streaks(src: Image, factor: int) -> Image:
	var strip := src.duplicate()
	strip.resize(SIZE / factor, SIZE, Image.INTERPOLATE_CUBIC)
	var out := Image.create(SIZE, SIZE, false, src.get_format())
	for k in factor:
		out.blit_rect(strip, Rect2i(0, 0, SIZE / factor, SIZE), Vector2i(k * SIZE / factor, 0))
	return out
