// Camera-facing water droplet for thin falling spray (see splat_emit.glsl).
// The instance transform holds position and size; custom data holds element
// id, seed and fill. Drawn after the liquid volume pass, blended, shaded as a
// glossy bead with a Fresnel rim so it reads as water against any backdrop.
shader_type spatial;
render_mode world_vertex_coords, cull_disabled, blend_mix, depth_draw_always;

uniform vec4 palette[16];
uniform sampler3D sunvis : filter_linear, repeat_disable;
uniform vec3 box_center = vec3(0.0);
uniform float box_half = 0.5;
uniform vec3 light_dir = vec3(0.4, 1.0, 0.3);

varying vec2 v_uv;
varying flat vec4 v_custom;
varying float v_vis;

void vertex() {
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
	if (r2 > 1.0) {
		discard;
	}
	vec3 n = normalize(vec3(d, sqrt(max(1.0 - r2, 0.0))));
	NORMAL = n;
	int id = int(v_custom.x + 0.5);
	vec3 tint = palette[id].rgb;
	float fresnel = pow(1.0 - n.z, 2.5);
	ALBEDO = mix(tint * 0.6, vec3(0.9, 0.95, 1.0), fresnel);
	ALPHA = clamp(0.35 + 0.55 * fresnel + 0.15 * (1.0 - v_custom.z), 0.0, 0.95);
	ROUGHNESS = 0.08;
	SPECULAR = 0.6;
}

void light() {
	float vis = LIGHT_IS_DIRECTIONAL ? v_vis : 1.0;
	float nl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	DIFFUSE_LIGHT += nl * ATTENUATION * LIGHT_COLOR * vis * 0.6;
	vec3 h = normalize(LIGHT + VIEW);
	float spec = pow(clamp(dot(NORMAL, h), 0.0, 1.0), 90.0) * 1.2;
	SPECULAR_LIGHT += spec * ATTENUATION * LIGHT_COLOR * vis;
}
