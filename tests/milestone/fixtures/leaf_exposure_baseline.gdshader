// Leaf card drawn from MultiMesh instances that splat_emit.glsl fills for
// plant cells exposed to air. The instance basis is the card's width (X),
// length (Y, from the cell outward) and normal (Z); custom data holds element
// id, seed, a phase and how many faces of the cell are exposed. Two-sided,
// alpha-scissored so it stays in the opaque pass, lit by Godot with sunlight
// scaled by the voxel sun-visibility field and a translucent back-light term.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform vec4 palette[32];
uniform sampler3D sunvis : filter_linear, repeat_disable;
uniform vec3 box_center = vec3(0.0);
uniform float box_half = 0.5;
uniform vec3 light_dir = vec3(0.4, 1.0, 0.3);
// Simulation seconds; sway stops when time is frozen.
uniform float sim_time = 0.0;
uniform float sway = 0.12;

varying vec2 v_local;
varying flat vec4 v_custom;
varying float v_vis;
// Interpolated per fragment: clipping the instance center lets geometry
// protrude across the section and makes whole cards pop at the boundary.
varying float v_section_cell;
uniform bool section_enabled = false;
uniform int section_axis = 2;
uniform int section_cell = 127;
uniform int grid_size = 128;

void vertex() {
	v_custom = INSTANCE_CUSTOM;
	// Anchor the card's base at the instance origin (the QuadMesh is centred).
	vec2 local = vec2(VERTEX.x, VERTEX.y + 0.5);
	v_local = local;
	float phase = v_custom.z * 6.2831853;
	float tip = local.y * local.y;
	float w = sin(sim_time * 2.1 + phase) * 0.6 + sin(sim_time * 3.7 + phase * 1.7) * 0.4;
	VERTEX = vec3(local.x + w * sway * tip, local.y - abs(w) * sway * 0.4 * tip, w * sway * 0.5 * tip);
	vec3 world_origin = MODEL_MATRIX[3].xyz;
	vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_section_cell = (world_vertex[section_axis] - box_center[section_axis] + box_half) / (2.0 * box_half) * float(grid_size);
	vec3 uvw = (world_origin - (box_center - vec3(box_half))) / (2.0 * box_half) + normalize(light_dir) * 0.02;
	v_vis = texture(sunvis, clamp(uvw, vec3(0.002), vec3(0.998))).r;
}

void fragment() {
	if (section_enabled && v_section_cell >= float(section_cell + 1)) { discard; }
	float y = clamp(v_local.y, 0.0, 1.0);
	// Leaf outline: widest a third of the way up, pointed at the tip.
	float half_w = 0.5 * pow(sin(3.14159 * pow(y, 0.75)), 0.8);
	float edge = half_w - abs(v_local.x);
	ALPHA = edge > 0.0 ? 1.0 : 0.0;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	int id = int(v_custom.x + 0.5);
	float seed = v_custom.y;
	vec3 base = palette[id].rgb;
	// Per-leaf variation: some yellower, some darker; inner cells darker.
	vec3 warm = vec3(0.55, 0.62, 0.18);
	vec3 col = mix(base, warm, seed * 0.45);
	col *= 0.8 + 0.45 * fract(seed * 7.31);
	col *= 0.75 + 0.25 * clamp(v_custom.w / 3.0, 0.0, 1.0);
	col *= 0.85 + 0.25 * y;
	// Midrib and veins.
	float rib = smoothstep(0.045, 0.01, abs(v_local.x)) * step(0.08, y);
	float vein = smoothstep(0.02, 0.0, abs(fract((y - abs(v_local.x) * 0.9) * 7.0) - 0.5) - 0.44);
	col *= 1.0 - 0.28 * rib - 0.1 * vein;
	col *= 1.0 - 0.35 * smoothstep(0.03, 0.0, edge);
	ALBEDO = col;
	ROUGHNESS = 0.62;
	SPECULAR = 0.35;
}

void light() {
	float vis = LIGHT_IS_DIRECTIONAL ? v_vis : 1.0;
	float nl = dot(NORMAL, LIGHT);
	float front = clamp(nl, 0.0, 1.0);
	float back = clamp(-nl, 0.0, 1.0) * 0.45;
	DIFFUSE_LIGHT += (front + back) * ATTENUATION * LIGHT_COLOR * vis;
	vec3 h = normalize(LIGHT + VIEW);
	float spec = pow(clamp(dot(NORMAL, h), 0.0, 1.0), 40.0) * 0.18;
	SPECULAR_LIGHT += spec * front * ATTENUATION * LIGHT_COLOR * vis;
}
