// Matte ground that receives the voxel world's shadow: for each point, the ray
// toward the sun is intersected with the sim box and the sun-visibility field
// is sampled where it enters, which gives a voxel-accurate soft shadow without
// rendering the volume into a shadow map.
shader_type spatial;

uniform vec4 albedo : source_color = vec4(0.88, 0.89, 0.91, 1.0);
uniform sampler3D sunvis : filter_linear, repeat_disable;
uniform vec3 box_center = vec3(0.0);
uniform float box_half = 0.5;
uniform vec3 to_sun = vec3(0.4, 1.0, 0.3);

varying float v_vis;

void fragment() {
	ALBEDO = albedo.rgb;
	ROUGHNESS = 1.0;
	vec3 p = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 d = normalize(to_sun);
	d = mix(d, vec3(1e-6), lessThan(abs(d), vec3(1e-6)));
	vec3 inv = 1.0 / d;
	vec3 lo = box_center - vec3(box_half);
	vec3 hi = box_center + vec3(box_half);
	vec3 t0 = (lo - p) * inv;
	vec3 t1 = (hi - p) * inv;
	vec3 tn = min(t0, t1);
	vec3 tf = max(t0, t1);
	float t_enter = max(max(tn.x, tn.y), tn.z);
	float t_exit = min(min(tf.x, tf.y), tf.z);
	float vis = 1.0;
	if (t_exit > max(t_enter, 0.0)) {
		vec3 q = p + d * (max(t_enter, 0.0) + 0.001);
		vec3 uv = (q - lo) / (2.0 * box_half);
		vis = texture(sunvis, clamp(uv, vec3(0.002), vec3(0.998))).r;
	}
	v_vis = vis;
}

void light() {
	float vis = LIGHT_IS_DIRECTIONAL ? v_vis : 1.0;
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR * vis;
}
