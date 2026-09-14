// Raymarches the voxel world stored in an RGBA8 3D texture (R = element id,
// G = per-voxel seed, B = liquid amount, A = flags), sampled as exact bytes.
// Drawn on a unit cube (model space [-0.5, 0.5]^3). Back faces are rendered so
// the camera can be inside the box. Writes DEPTH so ordinary meshes and the
// brush gizmo depth-test correctly against the voxels.
//
// Solids and powders are opaque cubes. Liquids are a smooth 0.5 isosurface of
// the density texture with Fresnel reflection, a sun highlight and
// Beer-Lambert tinting of whatever lies behind. Gases are participating media
// accumulated along the ray. A coarse occupancy grid (one texel per 8^3
// brick) lets rays leap over empty space. Output is premultiplied colour plus
// alpha so the scene outside the box shows through water and gas.
shader_type spatial;
render_mode cull_front, unshaded, blend_premul_alpha, depth_draw_always;

uniform sampler3D voxels : filter_nearest, repeat_disable;
uniform sampler3D occupancy : filter_nearest, repeat_disable;
uniform sampler3D density : filter_linear, repeat_disable;
uniform vec4 palette[16];
uniform float extinction[16];
uniform int grid_size = 128;
uniform int brick_size = 8;
uniform int liquid_mask = 0;
uniform int gas_mask = 0;
uniform float liquid_full = 200.0;
uniform vec3 light_dir = vec3(0.4, 1.0, 0.3);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.9);
uniform vec3 sky_color : source_color = vec3(0.74, 0.79, 0.84);
uniform vec3 ground_color : source_color = vec3(0.82, 0.84, 0.86);
uniform float ambient = 0.38;
// Per-voxel absorption of light inside liquid (r, g, b): water reads blue-green.
uniform vec3 absorb = vec3(0.10, 0.045, 0.02);
// In-scattering per voxel: gives the liquid a visible body in its own colour.
uniform float scatter = 0.05;
uniform float liquid_specular = 0.7;
uniform float liquid_f0 = 0.04;

varying vec3 v_model;
varying vec3 v_cam_model;

void vertex() {
	v_model = VERTEX;
	// Per-vertex (identical at every vertex) so the fragment stage skips the inverse.
	v_cam_model = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

// Returns the voxel as bytes: x = element id, y = seed, z = amount, w = flags.
uvec4 voxel_at(ivec3 cell) {
	return uvec4(texelFetch(voxels, cell, 0) * 255.0 + 0.5);
}

bool brick_empty(ivec3 cell) {
	return texelFetch(occupancy, cell / brick_size, 0).r < 0.5;
}

bool outside(ivec3 cell) {
	return any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(grid_size)));
}

bool is_liquid(uint id) { return (liquid_mask & (1 << int(id))) != 0; }
bool is_gas(uint id) { return (gas_mask & (1 << int(id))) != 0; }

// Smooth liquid density at a voxel-space point.
float dens(vec3 p) {
	return texture(density, p / float(grid_size)).r;
}

vec3 dens_normal(vec3 p) {
	const float e = 0.5;
	vec3 g = vec3(
		dens(p + vec3(e, 0, 0)) - dens(p - vec3(e, 0, 0)),
		dens(p + vec3(0, e, 0)) - dens(p - vec3(0, e, 0)),
		dens(p + vec3(0, 0, e)) - dens(p - vec3(0, 0, e)));
	return -normalize(g + vec3(1e-6));
}

vec3 hemi_light(vec3 n) {
	return mix(ground_color, sky_color, n.y * 0.5 + 0.5);
}

void fragment() {
	float G = float(grid_size);
	vec3 cam = v_cam_model;
	vec3 dir = normalize(v_model - cam);
	// Keep every component non-zero so 1/dir stays finite.
	dir = mix(dir, vec3(1e-6), lessThan(abs(dir), vec3(1e-6)));
	vec3 sun = normalize(light_dir);

	// Ray vs. the unit box (slab test).
	vec3 inv = 1.0 / dir;
	vec3 t_lo = (vec3(-0.5) - cam) * inv;
	vec3 t_hi = (vec3(0.5) - cam) * inv;
	vec3 t_near3 = min(t_lo, t_hi);
	vec3 t_far3 = max(t_lo, t_hi);
	float t_enter = max(max(t_near3.x, t_near3.y), t_near3.z);
	float t_exit = min(min(t_far3.x, t_far3.y), t_far3.z);
	float t_start = max(t_enter, 0.0);
	if (t_exit <= t_start) {
		DEPTH = 0.0;
		discard;
	}

	// Entry point in voxel space [0, G]^3, nudged inside. All ray distances
	// below are measured from p0 in voxel units.
	vec3 p0 = (cam + dir * t_start + 0.5) * G + dir * 1e-3;
	float t_box_exit = (t_exit - t_start) * G;
	ivec3 cell = clamp(ivec3(floor(p0)), ivec3(0), ivec3(grid_size - 1));

	// Amanatides-Woo setup.
	ivec3 step_dir = ivec3(sign(dir));
	vec3 pos_step = vec3(greaterThan(dir, vec3(0.0)));
	vec3 t_delta = abs(inv);
	vec3 t_max = (vec3(cell) + pos_step - p0) * inv;

	// Face we entered through (used if the very first voxel is solid).
	int axis = (t_near3.x > t_near3.y) ? ((t_near3.x > t_near3.z) ? 0 : 2) : ((t_near3.y > t_near3.z) ? 1 : 2);
	float t = 0.0;

	vec3 trans = vec3(1.0);     // light still reaching the eye from further along
	vec3 emitted = vec3(0.0);   // premultiplied colour gathered so far
	float t_first = -1.0;       // first surface, for DEPTH
	bool hit_solid = false;
	uvec4 value = uvec4(0u);

	// Liquid isosurface tracking.
	bool in_liquid = false;
	bool prev_liquid = false;
	float t_in = 0.0;
	vec3 liquid_col = vec3(0.0);
	vec3 liquid_shade = hemi_light(vec3(0.0, 1.0, 0.0)) * 0.9 + sun_color * 0.35;
	float d_prev = dens(p0);
	float t_prev = 0.0;
	{
		uint id0 = voxel_at(cell).x;
		if (is_liquid(id0) && d_prev >= 0.5) {
			in_liquid = true; // camera is under water
			liquid_col = palette[int(id0)].rgb;
		}
	}

	int max_steps = grid_size * 3;
	for (int i = 0; i < max_steps; i++) {
		if (brick_empty(cell) && !in_liquid && !prev_liquid) {
			// Leap to where the ray leaves this brick.
			ivec3 bmin = (cell / brick_size) * brick_size;
			vec3 planes = vec3(bmin) + pos_step * float(brick_size);
			vec3 tb = (planes - p0) * inv;
			t = min(tb.x, min(tb.y, tb.z));
			axis = (tb.x <= tb.y && tb.x <= tb.z) ? 0 : ((tb.y <= tb.z) ? 1 : 2);
			cell = ivec3(floor(p0 + dir * (t + 1e-3)));
			cell[axis] = (step_dir[axis] > 0) ? bmin[axis] + brick_size : bmin[axis] - 1;
			if (outside(cell)) {
				break;
			}
			t_max = (vec3(cell) + pos_step - p0) * inv;
			d_prev = 0.0;
			t_prev = t;
			continue;
		}
		value = voxel_at(cell);
		uint id = value.x;
		float t_next = min(t_max.x, min(t_max.y, t_max.z));
		bool liquid = is_liquid(id);

		if (id != 0u && !liquid && !is_gas(id)) {
			hit_solid = true;
			break;
		}

		if (id != 0u && !liquid) {
			// Gas: participating medium along this cell.
			float a = 1.0 - exp(-extinction[int(id)] * (t_next - t));
			vec4 pal = palette[int(id)];
			vec3 col = pal.rgb * (hemi_light(vec3(0.0, 1.0, 0.0)) * 0.85 + sun_color * 0.25) + pal.rgb * pal.a;
			emitted += trans * col * a;
			trans *= 1.0 - a;
			if (t_first < 0.0 && dot(trans, vec3(1.0 / 3.0)) < 0.6) {
				t_first = t;
			}
		}

		if (liquid || prev_liquid) {
			// Track the 0.5 isosurface across this cell.
			float d = dens(p0 + dir * t_next);
			if (!in_liquid && d >= 0.5) {
				float ta = t_prev, tb = t_next;
				for (int k = 0; k < 4; k++) {
					float tm = 0.5 * (ta + tb);
					if (dens(p0 + dir * tm) >= 0.5) { tb = tm; } else { ta = tm; }
				}
				float ts = tb;
				vec3 ps = p0 + dir * ts;
				vec3 n = dens_normal(ps);
				vec3 n_world = normalize(mat3(MODEL_MATRIX) * n);
				float cos_i = max(dot(-dir, n), 0.0);
				float fresnel = liquid_f0 + (1.0 - liquid_f0) * pow(1.0 - cos_i, 5.0);
				vec3 refl_dir = reflect(dir, n);
				vec3 refl_world = normalize(mat3(MODEL_MATRIX) * refl_dir);
				vec3 refl_col = hemi_light(refl_world) * 1.05;
				float spec = pow(max(dot(refl_world, sun), 0.0), 96.0) * liquid_specular;
				liquid_col = palette[int(liquid ? id : voxel_at(ivec3(floor(ps))).x)].rgb;
				float sheen = 0.12 * max(dot(n_world, sun), 0.0);
				emitted += trans * (fresnel * refl_col + spec * sun_color + sheen * liquid_col);
				trans *= 1.0 - fresnel;
				in_liquid = true;
				t_in = ts;
				if (t_first < 0.0) {
					t_first = ts;
				}
			} else if (in_liquid && d < 0.5) {
				float ta = t_prev, tb = t_next;
				for (int k = 0; k < 4; k++) {
					float tm = 0.5 * (ta + tb);
					if (dens(p0 + dir * tm) >= 0.5) { ta = tm; } else { tb = tm; }
				}
				float len = max(tb - t_in, 0.0);
				emitted += trans * liquid_col * liquid_shade * (1.0 - exp(-scatter * len));
				trans *= exp(-absorb * len);
				in_liquid = false;
			}
			d_prev = d;
			t_prev = t_next;
		}
		prev_liquid = liquid;

		if (max(trans.r, max(trans.g, trans.b)) < 0.01) {
			trans = vec3(0.0);
			break;
		}

		if (t_max.x < t_max.y && t_max.x < t_max.z) {
			cell.x += step_dir.x; t = t_max.x; t_max.x += t_delta.x; axis = 0;
		} else if (t_max.y < t_max.z) {
			cell.y += step_dir.y; t = t_max.y; t_max.y += t_delta.y; axis = 1;
		} else {
			cell.z += step_dir.z; t = t_max.z; t_max.z += t_delta.z; axis = 2;
		}
		if (outside(cell)) {
			break;
		}
	}

	float t_depth;
	if (hit_solid) {
		if (in_liquid) {
			float len = max(t - t_in, 0.0);
			emitted += trans * liquid_col * liquid_shade * (1.0 - exp(-scatter * len));
			trans *= exp(-absorb * len);
		}
		uint id = value.x;
		float seed = float(value.y) / 255.0;
		vec3 normal_model = vec3(0.0);
		normal_model[axis] = -float(step_dir[axis]);
		if (t_enter < 0.0 && t == 0.0) {
			normal_model = -dir; // camera is inside a solid voxel
		}
		vec3 normal_world = normalize(mat3(MODEL_MATRIX) * normal_model);
		vec4 pal = palette[int(id)];
		vec3 base = pal.rgb * (0.88 + 0.16 * seed);
		float diffuse = max(dot(normal_world, sun), 0.0);
		// Subtle per-face tint keeps cube edges readable in flat light.
		float face_tint = 0.9 + 0.1 * abs(normal_model.y) + 0.04 * abs(normal_model.x);
		vec3 lit = base * face_tint * (hemi_light(normal_world) * ambient + sun_color * diffuse * (1.0 - ambient * 0.5));
		emitted += trans * (lit + pal.rgb * pal.a);
		trans = vec3(0.0);
		t_depth = (t_first >= 0.0) ? t_first : t;
	} else {
		if (in_liquid) {
			float len = max(t_box_exit - t_in, 0.0);
			emitted += trans * liquid_col * liquid_shade * (1.0 - exp(-scatter * len));
			trans *= exp(-absorb * len);
		}
		if (t_first < 0.0 && max(trans.r, max(trans.g, trans.b)) > 0.995) {
			DEPTH = 0.0;
			discard; // nothing but air along this ray
		}
		t_depth = (t_first >= 0.0) ? t_first : t_box_exit;
	}

	vec3 hit_model = cam + dir * (t_start + t_depth / G);
	vec4 hit_view = VIEW_MATRIX * MODEL_MATRIX * vec4(hit_model, 1.0);
	vec4 hit_clip = PROJECTION_MATRIX * hit_view;
	DEPTH = hit_clip.z / hit_clip.w;

	ALBEDO = emitted;
	ALPHA = 1.0 - dot(trans, vec3(1.0 / 3.0));
}
