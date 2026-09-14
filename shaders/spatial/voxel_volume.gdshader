// Volume pass: liquids as the 0.5 isosurface of the liquid field (Fresnel
// reflection, sun highlight, in-scattering, Beer-Lambert absorption of what
// lies behind) and gases as participating media lit through the sun
// visibility field. Drawn after the opaque pass and stopped at its depth, so
// it never re-marches solids. Premultiplied alpha over the scene; depth is
// written at the first liquid or gas surface so sprites composite.
shader_type spatial;
render_mode cull_front, unshaded, blend_premul_alpha, depth_draw_always;

#include "res://shaders/spatial/voxel_dda.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform float extinction[16];
uniform float liquid_full = 200.0;
uniform vec3 absorb = vec3(0.10, 0.045, 0.02);
uniform float scatter = 0.05;
uniform float liquid_specular = 0.7;
uniform float liquid_f0 = 0.04;
uniform float ambient = 0.38;
// 0 normal, 1 ignore the opaque depth, 2 show t_stop / t_box as grey,
// 3 diagnostics: R liquid entry seen, G liquid cell visited, B leaps / 16
uniform int volume_debug = 0;

void vertex() {
	v_model = VERTEX;
	v_cam_model = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

void fragment() {
	Ray r;
	if (!setup_ray(v_model, v_cam_model, r)) {
		DEPTH = 0.0;
		discard;
	}
	float G = float(grid_size);
	vec3 sun = normalize(light_dir);

	// Where the opaque pass already drew something along this ray.
	float t_stop = r.t_box;
	float z = texture(depth_tex, SCREEN_UV).r;
	if (z > 0.0) {
		vec4 ndc = vec4(SCREEN_UV * 2.0 - 1.0, z, 1.0);
		vec4 view = INV_PROJECTION_MATRIX * ndc;
		view.xyz /= view.w;
		vec3 world = (INV_VIEW_MATRIX * vec4(view.xyz, 1.0)).xyz;
		vec3 model = (inverse(MODEL_MATRIX) * vec4(world, 1.0)).xyz;
		float t_world = dot(model - r.cam, r.dir);
		t_stop = clamp((t_world - r.t_start) * G, 0.0, r.t_box);
	}
	if (volume_debug == 1) {
		t_stop = r.t_box;
	}
	float debug_t = t_stop / r.t_box;

	float t = 0.0;
	vec3 trans = vec3(1.0);
	vec3 emitted = vec3(0.0);
	float t_first = -1.0;
	bool in_liquid = false;
	bool prev_liquid = false;
	float t_in = 0.0;
	vec3 liquid_col = vec3(0.0);
	vec3 liquid_shade = hemi_light(vec3(0.0, 1.0, 0.0)) * 0.9 + sun_color * 0.35;
	float f_prev = field(r.p0).r;
	float t_prev = 0.0;
	float dbg_entry = 0.0;
	float dbg_visited = 0.0;
	float dbg_leaps = 0.0;
	{
		uint id0 = voxel_at(r.cell).x;
		if (is_liquid(id0) && f_prev >= 0.5) {
			in_liquid = true;
			liquid_col = palette[int(id0)].rgb;
		}
	}

	int max_steps = grid_size * 3;
	for (int i = 0; i < max_steps; i++) {
		if (t >= t_stop) {
			break;
		}
		if (brick_empty(r.cell, 1) && !in_liquid && !prev_liquid) {
			dbg_leaps += 1.0;
			if (!leap_brick(r, t)) {
				break;
			}
			f_prev = 0.0;
			t_prev = t;
			continue;
		}
		uvec4 value = voxel_at(r.cell);
		uint id = value.x;
		float t_next = min(min(r.t_max.x, min(r.t_max.y, r.t_max.z)), t_stop);
		bool liquid = is_liquid(id);
		float f = field(r.p0 + r.dir * t_next).r;
		if (liquid) { dbg_visited = 1.0; }

		if (id != 0u && !liquid && is_gas(id)) {
			float len = max(t_next - t, 0.0);
			float a = 1.0 - exp(-extinction[int(id)] * len);
			vec4 pal = palette[int(id)];
			vec3 mid = r.p0 + r.dir * (0.5 * (t + t_next));
			float vis = sun_vis(mid + sun * 1.5);
			vec3 col = pal.rgb * (hemi_light(vec3(0.0, 1.0, 0.0)) * 0.7 + sun_color * 0.6 * vis) + pal.rgb * pal.a;
			emitted += trans * col * a;
			trans *= 1.0 - a;
			if (t_first < 0.0 && dot(trans, vec3(1.0 / 3.0)) < 0.6) {
				t_first = t;
			}
		}

		if (liquid || prev_liquid) {
			if (!in_liquid && f >= 0.5) {
				float ts = bisect(r.p0, r.dir, t_prev, t_next, 0, true);
				vec3 ps = r.p0 + r.dir * ts;
				float lap;
				vec3 n = -normalize(field_gradient(ps, 0, 0.5, lap) + vec3(1e-6));
				vec3 n_world = normalize(mat3(MODEL_MATRIX) * n);
				float cos_i = max(dot(-r.dir, n), 0.0);
				float fresnel = liquid_f0 + (1.0 - liquid_f0) * pow(1.0 - cos_i, 5.0);
				vec3 refl_world = normalize(mat3(MODEL_MATRIX) * reflect(r.dir, n));
				vec3 refl_col = hemi_light(refl_world) * 1.05;
				float vis = sun_vis(ps + n * 0.75 + sun * 1.25);
				float spec = pow(max(dot(refl_world, sun), 0.0), 96.0) * liquid_specular * vis;
				liquid_col = palette[int(liquid ? id : voxel_at(ivec3(floor(ps))).x)].rgb;
				float sheen = 0.12 * max(dot(n_world, sun), 0.0) * vis;
				emitted += trans * (fresnel * refl_col + spec * sun_color + sheen * liquid_col);
				trans *= 1.0 - fresnel;
				in_liquid = true;
				dbg_entry = 1.0;
				t_in = ts;
				if (t_first < 0.0) {
					t_first = ts;
				}
			} else if (in_liquid && f < 0.5) {
				float ts = bisect(r.p0, r.dir, t_prev, t_next, 0, false);
				float len = max(ts - t_in, 0.0);
				emitted += trans * liquid_col * liquid_shade * (1.0 - exp(-scatter * len));
				trans *= exp(-absorb * len);
				in_liquid = false;
			}
		}
		f_prev = f;
		t_prev = t_next;
		prev_liquid = liquid;

		if (max(trans.r, max(trans.g, trans.b)) < 0.01) {
			trans = vec3(0.0);
			break;
		}
		if (t_next >= t_stop) {
			t = t_stop;
			break;
		}
		if (!step_voxel(r, t)) {
			break;
		}
	}

	if (in_liquid) {
		float len = max(min(t_stop, r.t_box) - t_in, 0.0);
		emitted += trans * liquid_col * liquid_shade * (1.0 - exp(-scatter * len));
		trans *= exp(-absorb * len);
	}
	if (volume_debug < 2 && t_first < 0.0 && max(trans.r, max(trans.g, trans.b)) > 0.995) {
		DEPTH = 0.0;
		discard;
	}
	float t_depth = (t_first >= 0.0) ? t_first : min(t_stop, r.t_box);
	vec3 hit_model = r.cam + r.dir * (r.t_start + t_depth / G);
	vec4 hit_clip = PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX * vec4(hit_model, 1.0);
	DEPTH = hit_clip.z / hit_clip.w;
	ALBEDO = emitted;
	ALPHA = 1.0 - dot(trans, vec3(1.0 / 3.0));
	if (volume_debug == 2) {
		ALBEDO = vec3(debug_t);
		ALPHA = 1.0;
	}
	if (volume_debug == 3) {
		ALBEDO = vec3(dbg_entry, dbg_visited, dbg_leaps / 16.0);
		ALPHA = 1.0;
	}
}
