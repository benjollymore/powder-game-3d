// Camera-facing grain splat drawn from MultiMesh instances that a compute pass
// fills every frame (see splat_emit.glsl). Each instance's transform holds
// the grain's model-space position and size; custom data holds element id,
// seed and age. Shaded as a tiny sphere, lit by Godot, alpha-scissored so it
// stays in the opaque pass and needs no sorting.
shader_type spatial;
render_mode world_vertex_coords, cull_disabled;

uniform vec4 palette[16];
uniform sampler3D sunvis : filter_linear, repeat_disable;
uniform vec3 box_center = vec3(0.0);
uniform float box_half = 0.5;
uniform vec3 light_dir = vec3(0.4, 1.0, 0.3); // toward the sun, world space

varying vec2 v_uv;
varying flat vec4 v_custom;
varying float v_vis;

void vertex() {
	// With world_vertex_coords VERTEX arrives in world space, so the quad's
	// local corner comes from UV instead.
	vec3 origin = MODEL_MATRIX[3].xyz;
	float size = length(MODEL_MATRIX[0].xyz);
	v_uv = UV - 0.5;
	v_custom = INSTANCE_CUSTOM;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	VERTEX = origin + (right * v_uv.x + up * v_uv.y) * size;
	NORMAL = INV_VIEW_MATRIX[2].xyz;
	vec3 uvw = (origin - (box_center - vec3(box_half))) / (2.0 * box_half) + normalize(light_dir) * 0.02;
	v_vis = texture(sunvis, clamp(uvw, vec3(0.002), vec3(0.998))).r;
}

void fragment() {
	vec2 d = v_uv * 2.0;
	float r2 = dot(d, d);
	ALPHA = (r2 < 1.0) ? 1.0 : 0.0;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	// Fake sphere normal in view space.
	vec3 n = vec3(d, sqrt(max(1.0 - r2, 0.0)));
	NORMAL = normalize(n);
	int id = int(v_custom.x + 0.5);
	vec3 col = palette[id].rgb * (0.9 + 0.2 * v_custom.y);
	ALBEDO = col;
	ROUGHNESS = 0.9;
}

void light() {
	float vis = LIGHT_IS_DIRECTIONAL ? v_vis : 1.0;
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR * vis;
}
