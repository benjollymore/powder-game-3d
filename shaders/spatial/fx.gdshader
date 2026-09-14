// FX pool sprites (see fx.glsl): embers, dust and splash droplets as soft
// camera-facing discs. Custom data: kind, life fraction, seed, speed.
// Unshaded: embers are emissive and bloom, dust and splash take a simple
// sun and sky term scaled by the voxel sun-visibility field.
shader_type spatial;
render_mode world_vertex_coords, cull_disabled, blend_mix, depth_draw_never, unshaded;

uniform sampler3D sunvis : filter_linear, repeat_disable;
uniform vec3 box_center = vec3(0.0);
uniform float box_half = 0.5;
uniform vec3 light_dir = vec3(0.4, 1.0, 0.3);
uniform vec3 sun_color = vec3(1.0);
uniform vec3 dust_color : source_color = vec3(0.78, 0.68, 0.5);
uniform float sim_time = 0.0;

varying vec2 v_uv;
varying flat vec4 v_custom;
varying float v_vis;
varying flat float v_section_cell;
uniform bool section_enabled = false;
uniform int section_axis = 2;
uniform int section_cell = 127;
uniform int grid_size = 128;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	v_section_cell = (origin[section_axis] - box_center[section_axis] + box_half) / (2.0 * box_half) * float(grid_size);
	float size = length(MODEL_MATRIX[0].xyz);
	v_uv = UV - 0.5;
	v_custom = INSTANCE_CUSTOM;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	VERTEX = origin + (right * v_uv.x + up * v_uv.y) * size;
	vec3 uvw = (origin - (box_center - vec3(box_half))) / (2.0 * box_half) + normalize(light_dir) * 0.02;
	v_vis = texture(sunvis, clamp(uvw, vec3(0.002), vec3(0.998))).r;
}

void fragment() {
	if (section_enabled && v_section_cell >= float(section_cell + 1)) { discard; }
	vec2 d = v_uv * 2.0;
	float r2 = dot(d, d);
	if (r2 > 1.0) {
		discard;
	}
	int kind = int(v_custom.x + 0.5);
	float t = v_custom.y;
	float seed = v_custom.z;
	float soft = 1.0 - r2;
	if (kind == 1) {
		// Ember: white-hot core cooling to red, flickering, fading out.
		float heat = 1.0 - t;
		float flicker = 0.75 + 0.25 * sin(sim_time * 37.0 + seed * 250.0);
		vec3 hot = mix(vec3(1.0, 0.25, 0.04), vec3(1.0, 0.85, 0.5), heat * heat);
		float core = smoothstep(0.0, 1.0, soft);
		ALBEDO = hot * (2.5 + 4.0 * heat) * flicker * core;
		ALPHA = clamp(core * (0.6 + 0.4 * heat), 0.0, 1.0);
	} else if (kind == 2) {
		// Dust: soft puff that spreads and thins.
		float sun = 0.55 + 0.45 * v_vis;
		ALBEDO = dust_color * sun * (0.6 + 0.4 * seed);
		float fade = sin(3.14159 * clamp(t, 0.0, 1.0));
		ALPHA = soft * soft * 0.22 * fade;
	} else {
		// Splash droplet: bright bead.
		float n_z = sqrt(max(1.0 - r2, 0.0));
		float fresnel = pow(1.0 - n_z, 2.0);
		ALBEDO = mix(vec3(0.35, 0.55, 0.85), vec3(1.0), 0.4 + 0.6 * fresnel) * (0.7 + 0.5 * v_vis);
		ALPHA = (0.55 + 0.4 * fresnel) * (1.0 - t * t);
	}
}
