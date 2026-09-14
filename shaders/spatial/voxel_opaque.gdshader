// Opaque pass: solids and powders as the 0.5 isosurface of the smoothed
// field, shaded with triplanar textures, grain, cone-traced AO and curvature.
// A lit material: Godot adds sky ambient, specular, SSAO, fog, DOF and glow;
// direct sunlight is multiplied by the voxel sun-visibility field in light().
shader_type spatial;
render_mode cull_front, depth_draw_opaque;

#include "res://shaders/spatial/voxel_dda.gdshaderinc"

uniform sampler2DArray albedo_maps : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray normal_maps : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler3D grain_noise : filter_linear, repeat_enable;
uniform int mat_layer[16];
uniform float mat_smooth[16];
uniform float mat_grain[16];
uniform float mat_rough[16];
uniform float texture_tile = 16.0;
uniform float texture_size = 256.0;
uniform float ao_strength = 1.0;
// 0 normal, 1 flat colour, 2 AO only, 3 smoothed normal, 4 texture only, 5 sun visibility
uniform int debug_mode = 0;

varying float v_sunvis;

void vertex() {
	v_model = VERTEX;
	v_cam_model = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

vec3 triplanar(sampler2DArray maps, vec3 p, vec3 bw, int layer, float lod) {
	vec3 uvw = p / texture_tile;
	return bw.x * textureLod(maps, vec3(uvw.yz, float(layer)), lod).rgb
		 + bw.y * textureLod(maps, vec3(uvw.xz, float(layer)), lod).rgb
		 + bw.z * textureLod(maps, vec3(uvw.xy, float(layer)), lod).rgb;
}

void fragment() {
	Ray r;
	if (!setup_ray(v_model, v_cam_model, r)) {
		DEPTH = 0.0;
		discard;
	}
	float G = float(grid_size);
	float t = 0.0;
	bool hit = false;
	float t_hit = 0.0;
	uvec4 value = uvec4(0u);
	float g_prev = field(r.p0).g;
	float t_prev = 0.0;
	{
		uint id0 = voxel_at(r.cell).x;
		if (is_opaque(id0) && g_prev >= 0.5) {
			hit = true; // camera inside a solid
			value = voxel_at(r.cell);
		}
	}

	int max_steps = grid_size * 3;
	for (int i = 0; i < max_steps && !hit; i++) {
		if (brick_empty(r.cell, 0)) {
			if (!leap_brick(r, t)) {
				break;
			}
			g_prev = 0.0;
			t_prev = t;
			continue;
		}
		float t_next = min(r.t_max.x, min(r.t_max.y, r.t_max.z));
		float g = field(r.p0 + r.dir * t_next).g;
		if (g >= 0.5 && g_prev < 0.5) {
			t_hit = bisect(r.p0, r.dir, t_prev, t_next, 1, true);
			value = voxel_at(r.cell);
			hit = true;
			break;
		}
		g_prev = g;
		t_prev = t_next;
		if (!step_voxel(r, t)) {
			break;
		}
	}
	if (!hit) {
		DEPTH = 0.0;
		discard;
	}

	vec3 ps = r.p0 + r.dir * t_hit;
	float lap;
	vec3 grad = field_gradient(ps, 1, 1.0, lap);
	vec3 n_model = -normalize(grad + vec3(1e-6));
	vec3 n_coarse = -normalize(field_gradient_coarse(ps, 1.0, 2.0) + vec3(1e-6));
	if (dot(n_coarse, n_model) > 0.0) {
		n_model = normalize(mix(n_model, n_coarse, 0.75));
	}
	// Which element: the opaque voxel just behind the surface, else ahead, else the DDA cell.
	ivec3 behind = ivec3(floor(ps - n_model * 0.6));
	uvec4 hv = outside(behind) ? value : voxel_at(behind);
	if (!is_opaque(hv.x)) {
		ivec3 ahead = ivec3(floor(ps + r.dir * 0.5));
		hv = outside(ahead) ? value : voxel_at(ahead);
	}
	if (!is_opaque(hv.x)) {
		hv = value;
	}
	uint id = is_opaque(hv.x) ? hv.x : 1u;
	float seed = float(hv.y) / 255.0;
	vec3 face_model = vec3(0.0);
	face_model[r.axis] = -float(r.step_dir[r.axis]);
	if (t_hit == 0.0) {
		face_model = -r.dir;
		n_model = -r.dir;
	}

	mat3 model_basis = mat3(MODEL_MATRIX);
	float sm = mat_smooth[int(id)];
	vec3 n = normalize(mix(face_model, n_model, sm));
	int layer = mat_layer[int(id)];
	vec3 hit_model = r.cam + r.dir * (r.t_start + t_hit / G);
	vec4 hit_view = VIEW_MATRIX * MODEL_MATRIX * vec4(hit_model, 1.0);
	vec3 view_dir_world = normalize(model_basis * normalize((r.cam + 0.5) * G - ps));

	// Analytic LOD, grown at grazing angles (explicit LOD has no anisotropy).
	float footprint_world = 2.0 * (-hit_view.z) / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float voxels_per_unit = G / length(model_basis[0]);
	float grazing = 1.0 / max(abs(dot(normalize(model_basis * n), view_dir_world)), 0.25);
	float lod = clamp(log2(max(footprint_world * voxels_per_unit / texture_tile * texture_size * grazing, 1e-4)), 0.0, 8.0);

	vec3 bw = pow(abs(n), vec3(4.0));
	bw /= bw.x + bw.y + bw.z;
	vec3 tex = triplanar(albedo_maps, ps, bw, layer, lod);
	vec3 tn = triplanar(normal_maps, ps, bw, layer, lod) * 2.0 - 1.0;
	vec3 pert = bw.x * vec3(0.0, tn.x, tn.y) + bw.y * vec3(tn.x, 0.0, tn.y) + bw.z * vec3(tn.x, tn.y, 0.0);
	vec3 gn = texture(grain_noise, ps / 8.0).rgb * 2.0 - 1.0;
	n = normalize(n + pert * 0.6 + gn * mat_grain[int(id)]);

	vec4 pal = palette[int(id)];
	vec3 base = pal.rgb * (0.94 + 0.12 * seed) * (0.55 + 0.9 * tex);
	base *= 1.0 - clamp(lap * 0.5, -0.12, 0.12) * sm;

	float ao = 1.0;
	ao -= 0.35 * field_g(ps + n * 1.5, 0.0);
	ao -= 0.25 * field_g(ps + n * 3.0, 1.0);
	ao -= 0.2 * field_g(ps + n * 6.0, 2.0);
	ao -= 0.1 * field_g(ps + n * 12.0, 3.0);
	ao -= 0.15 * field_g(ps + vec3(0.0, 8.0, 0.0), 2.0);
	ao = mix(1.0, clamp(ao, 0.15, 1.0), ao_strength);

	vec3 to_sun_model = normalize(light_dir); // uniform scale: world and model directions agree
	v_sunvis = sun_vis(ps + n * 0.75 + to_sun_model * 1.25);

	vec3 n_world = normalize(model_basis * n);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	ALBEDO = base;
	ROUGHNESS = mat_rough[int(id)];
	METALLIC = 0.0;
	AO = ao;
	AO_LIGHT_AFFECT = 0.0;
	LIGHT_VERTEX = hit_view.xyz;
	vec4 hit_clip = PROJECTION_MATRIX * hit_view;
	DEPTH = hit_clip.z / hit_clip.w;

	if (debug_mode == 1) { ALBEDO = pal.rgb; ROUGHNESS = 1.0; }
	if (debug_mode == 2) { ALBEDO = vec3(ao); EMISSION = vec3(ao); }
	if (debug_mode == 3) { ALBEDO = vec3(0.0); EMISSION = n * 0.5 + 0.5; }
	if (debug_mode == 4) { ALBEDO = vec3(0.0); EMISSION = tex; }
	if (debug_mode == 5) { ALBEDO = vec3(0.0); EMISSION = vec3(v_sunvis); }
}

void light() {
	float vis = LIGHT_IS_DIRECTIONAL ? v_sunvis : 1.0;
	float nl = clamp(dot(NORMAL, LIGHT), 0.0, 1.0);
	DIFFUSE_LIGHT += nl * ATTENUATION * LIGHT_COLOR * vis;
	vec3 h = normalize(LIGHT + VIEW);
	float shininess = 8.0 + 120.0 * (1.0 - ROUGHNESS);
	float spec = pow(clamp(dot(NORMAL, h), 0.0, 1.0), shininess) * (0.03 + 0.25 * (1.0 - ROUGHNESS));
	SPECULAR_LIGHT += spec * nl * ATTENUATION * LIGHT_COLOR * vis / 3.14159;
}
