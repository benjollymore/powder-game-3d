class_name MaterialLibrary
extends RefCounted
## Procedural placeholder PBR textures for the voxel materials, built at boot
## so the pipeline is not gated on assets. Layer index = "mat" in Elements.
## Replace with CC0 textures (ambientCG) by loading images into the same arrays.

const SIZE := 256
const LAYERS := 4  # 0 stone, 1 sand, 2 plant, 3 generic

static var _albedo: Texture2DArray
static var _normal: Texture2DArray
static var _grain: NoiseTexture3D


static func apply(material: ShaderMaterial) -> void:
	if _albedo == null:
		_build()
	material.set_shader_parameter("albedo_maps", _albedo)
	material.set_shader_parameter("normal_maps", _normal)
	material.set_shader_parameter("grain_noise", _grain)
	material.set_shader_parameter("mat_layer", Elements.material_layers())
	material.set_shader_parameter("mat_smooth", Elements.floats("smooth"))
	material.set_shader_parameter("mat_grain", Elements.floats("grain"))
	material.set_shader_parameter("mat_rough", Elements.floats("rough", 0.8))
	material.set_shader_parameter("texture_size", float(SIZE))


static func _build() -> void:
	var albedos: Array[Image] = []
	var normals: Array[Image] = []
	# [frequency, octaves, contrast, bump strength] per layer
	var params := [
		[0.03, 5, 1.1, 2.5],   # stone: coarse, moderate relief
		[0.12, 3, 0.7, 2.0],   # sand: fine, low contrast
		[0.06, 4, 1.1, 3.0],   # plant
		[0.05, 4, 1.0, 3.0],   # generic
	]
	for i in LAYERS:
		var n := FastNoiseLite.new()
		n.seed = 100 + i
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = params[i][0]
		n.fractal_octaves = params[i][1]
		var height := n.get_seamless_image(SIZE, SIZE, false, false, 0.1, true)
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
