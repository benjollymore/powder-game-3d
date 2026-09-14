class_name InstanceLayer
extends MultiMeshInstance3D
## A MultiMesh whose instance buffer is filled on the GPU (splat_emit.glsl,
## fx.glsl). Nothing here touches instance data from the CPU after
## allocation: that would re-enable Godot's CPU-side cache and clobber the
## GPU writes. Unused instances are zero-size and cost nothing to draw.

## Instance slots; sets the storage buffer size (64 bytes each).
@export var capacity := 131072
## Which emit kernel output fills this layer: grains, leaves, droplets, fx.
@export_enum("grains", "leaves", "droplets", "fx") var role := 0


func _ready() -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.use_colors = false
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mm.mesh = quad
	# A custom AABB on the resource stops Godot recomputing bounds from the
	# buffer every frame (a GPU readback) once the GPU owns the instance data.
	mm.custom_aabb = AABB(Vector3(-0.6, -0.6, -0.6), Vector3(1.2, 1.2, 1.2))
	mm.instance_count = capacity
	multimesh = mm
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Debug: `splatdebug=1` places one CPU-set instance at the top of the box to
	# prove the draw path independently of the GPU emit pass.
	for arg in OS.get_cmdline_user_args():
		# `hide=<role>` skips drawing a layer (its GPU fill still runs): benchmarks.
		if arg == "hide=" + ["grains", "leaves", "droplets", "fx"][role]:
			visible = false
		if arg == "splatdebug=1":
			mm.set_instance_transform(0, Transform3D(Basis().scaled(Vector3.ONE * 0.08), Vector3(0.0, 0.35, 0.0)))
			mm.set_instance_custom_data(0, Color(2.0, 0.5, 3.0, 0.0))


## RD storage buffer behind the MultiMesh (valid once the RD has allocated it).
func buffer_rd_rid() -> RID:
	return RenderingServer.multimesh_get_buffer_rd_rid(multimesh.get_rid())
