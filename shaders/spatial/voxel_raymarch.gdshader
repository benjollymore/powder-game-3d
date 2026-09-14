// Raymarches the voxel world stored in an RGBA8 3D texture (R = element id,
// G = per-voxel seed, B = liquid amount, A = flags), sampled as exact bytes,
// together with the renderer "fields" texture (R liquid density, G smoothed
// opaque density, B gas) and its mips.
// Drawn on a unit cube (model space [-0.5, 0.5]^3). Back faces are rendered so
// the camera can be inside the box. Writes DEPTH so ordinary meshes and the
// brush gizmo depth-test correctly against the voxels.
//
// Solids and powders are the 0.5 isosurface of the smoothed field: walls stay
// crisp cubes (smooth 0), sand becomes a heap (smooth 1). They are shaded with
// triplanar textures, a grain normal, cone-traced ambient occlusion from the
// field mips and curvature darkening. Liquids are the 0.5 isosurface of the
// liquid field with Fresnel reflection, a sun highlight and Beer-Lambert
// tinting of whatever lies behind. Gases are participating media. Output is
// premultiplied colour plus alpha so the scene outside the box shows through.
shader_type spatial;
render_mode cull_front, unshaded, blend_premul_alpha, depth_draw_always;

uniform sampler3D voxels : filter_nearest, repeat_disable;
uniform sampler3D occupancy : filter_nearest, repeat_disable;
uniform sampler3D fields : filter_linear_mipmap, repeat_disable;
uniform sampler2DArray albedo_maps : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2DArray normal_maps : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler3D grain_noise : filter_linear, repeat_enable;
uniform vec4 palette[16];
uniform float extinction[16];
uniform int mat_layer[16];
uniform float mat_smooth[16];
uniform float mat_grain[16];
uniform float mat_rough[16];
uniform int grid_size = 128;
uniform int brick_size = 8;
uniform int liquid_mask = 0;
uniform int gas_mask = 0;
uniform float liquid_full = 200.0;
uniform float texture_tile = 16.0; // voxels per texture repeat
uniform float texture_size = 256.0;
uniform vec3 light_dir = vec3(0.4, 1.0, 0.3);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.9);
uniform vec3 sky_color : source_color = vec3(0.74, 0.79, 0.84);
uniform vec3 ground_color : source_color = vec3(0.82, 0.84, 0.86);
uniform float ambient = 0.38;
uniform vec3 absorb = vec3(0.10, 0.045, 0.02);
uniform float scatter = 0.05;
uniform float liquid_specular = 0.7;
uniform float liquid_f0 = 0.04;
// 0 normal, 1 flat colour, 2 AO only, 3 smoothed normal, 4 texture only, 5 face normal only
uniform int debug_mode = 0;

varying vec3 v_model;
varying vec3 v_cam_model;

void vertex() {
	v_model = VERTEX;
	v_cam_model = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

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
bool is_opaque(uint id) { return id != 0u && !is_liquid(id) && !is_gas(id); }

vec4 field(vec3 p) { return textureLod(fields, p / float(grid_size), 0.0); }
float field_g(vec3 p, float lod) { return textureLod(fields, p / float(grid_size), lod).g; }

vec3 hemi_light(vec3 n) {
	return mix(ground_color, sky_color, n.y * 0.5 + 0.5);
}

// Finds the crossing of channel `ch` of the field with 0.5 between ta and tb.
float bisect(vec3 p0, vec3 dir, float ta, float tb, int ch, bool rising) {
	for (int k = 0; k < 4; k++) {
		float tm = 0.5 * (ta + tb);
		float d = (ch == 0) ? field(p0 + dir * tm).r : field(p0 + dir * tm).g;
		bool above = d >= 0.5;
		if (above == rising) { tb = tm; } else { ta = tm; }
	}
	return tb;
}

vec3 field_gradient(vec3 p, int ch, float e, out float lap) {
	float c = (ch == 0) ? field(p).r : field(p).g;
	vec3 gp, gm;
	if (ch == 0) {
		gp = vec3(field(p + vec3(e, 0, 0)).r, field(p + vec3(0, e, 0)).r, field(p + vec3(0, 0, e)).r);
		gm = vec3(field(p - vec3(e, 0, 0)).r, field(p - vec3(0, e, 0)).r, field(p - vec3(0, 0, e)).r);
	} else {
		gp = vec3(field(p + vec3(e, 0, 0)).g, field(p + vec3(0, e, 0)).g, field(p + vec3(0, 0, e)).g);
		gm = vec3(field(p - vec3(e, 0, 0)).g, field(p - vec3(0, e, 0)).g, field(p - vec3(0, 0, e)).g);
	}
	lap = dot(gp + gm, vec3(1.0)) - 6.0 * c;
	return gp - gm;
}

// Gradient of the smoothed opaque field at a coarser mip: hides the one-voxel
// stairs the 3^3 kernel leaves on steep slopes.
vec3 field_gradient_coarse(vec3 p, float lod, float e) {
	vec3 gp = vec3(field_g(p + vec3(e, 0, 0), lod), field_g(p + vec3(0, e, 0), lod), field_g(p + vec3(0, 0, e), lod));
	vec3 gm = vec3(field_g(p - vec3(e, 0, 0), lod), field_g(p - vec3(0, e, 0), lod), field_g(p - vec3(0, 0, e), lod));
	return gp - gm;
}

// Triplanar sample of a texture array layer with an explicit LOD.
vec3 triplanar(sampler2DArray maps, vec3 p, vec3 bw, int layer, float lod) {
	vec3 uvw = p / texture_tile;
	return bw.x * textureLod(maps, vec3(uvw.yz, float(layer)), lod).rgb
		 + bw.y * textureLod(maps, vec3(uvw.xz, float(layer)), lod).rgb
		 + bw.z * textureLod(maps, vec3(uvw.xy, float(layer)), lod).rgb;
}

// Shade an opaque hit at voxel-space point ps with smoothed normal n_model.
vec3 shade_opaque(vec3 ps, vec3 n_model, vec3 face_model, uint id, float seed, float dist_view, vec2 viewport, float proj_y, mat3 model_basis, vec3 cam_voxel) {
	float sm = mat_smooth[int(id)];
	vec3 n = normalize(mix(face_model, n_model, sm));
	int layer = mat_layer[int(id)];
	vec3 view_dir_world = normalize(model_basis * normalize(cam_voxel - ps));

	// Analytic LOD: pixel footprint in texels at this distance. The box is
	// grid_size voxels across length(model_basis[0]) world units.
	float footprint_world = 2.0 * dist_view / (proj_y * viewport.y);
	float voxels_per_unit = float(grid_size) / length(model_basis[0]);
	// Explicit LOD gets no anisotropic filtering, so grow the footprint at grazing angles.
	float grazing = 1.0 / max(abs(dot(normalize(model_basis * n), view_dir_world)), 0.25);
	float footprint_tex = footprint_world * voxels_per_unit / texture_tile * texture_size * grazing;
	float lod = clamp(log2(max(footprint_tex, 1e-4)), 0.0, 8.0);

	vec3 bw = pow(abs(n), vec3(4.0));
	bw /= bw.x + bw.y + bw.z;
	vec3 tex = triplanar(albedo_maps, ps, bw, layer, lod);
	vec3 tn = triplanar(normal_maps, ps, bw, layer, lod) * 2.0 - 1.0;
	// UDN-style blend: perturb the normal in the two axes of each plane.
	vec3 pert = bw.x * vec3(0.0, tn.x, tn.y) + bw.y * vec3(tn.x, 0.0, tn.y) + bw.z * vec3(tn.x, tn.y, 0.0);
	float grain = mat_grain[int(id)];
	vec3 gn = texture(grain_noise, ps / 8.0).rgb * 2.0 - 1.0;
	n = normalize(n + pert * 0.6 + gn * grain);

	vec4 pal = palette[int(id)];
	vec3 base = pal.rgb * (0.94 + 0.12 * seed) * (0.55 + 0.9 * tex);

	// Ambient occlusion from cone taps on the field mips along the normal.
	float ao = 1.0;
	ao -= 0.35 * field_g(ps + n * 1.5, 0.0);
	ao -= 0.25 * field_g(ps + n * 3.0, 1.0);
	ao -= 0.2 * field_g(ps + n * 6.0, 2.0);
	ao -= 0.1 * field_g(ps + n * 12.0, 3.0);
	ao -= 0.15 * field_g(ps + vec3(0.0, 8.0, 0.0), 2.0);
	ao = clamp(ao, 0.15, 1.0);

	vec3 n_world = normalize(model_basis * n);
	vec3 sun = normalize(light_dir);
	float diffuse = max(dot(n_world, sun), 0.0);
	float rough = mat_rough[int(id)];
	vec3 h = normalize(sun + view_dir_world);
	float spec = pow(max(dot(n_world, h), 0.0), 8.0 + 120.0 * (1.0 - rough)) * (0.03 + 0.25 * (1.0 - rough));
	vec3 lit = base * (hemi_light(n_world) * ambient * ao + sun_color * diffuse * (1.0 - ambient * 0.5))
			 + sun_color * spec * diffuse;
	if (debug_mode == 1) { return pal.rgb * (0.4 + 0.6 * max(dot(normalize(model_basis * normalize(mix(face_model, n_model, sm))), sun), 0.0)); }
	if (debug_mode == 2) { return vec3(ao); }
	if (debug_mode == 3) { return normalize(mix(face_model, n_model, sm)) * 0.5 + 0.5; }
	if (debug_mode == 4) { return tex; }
	if (debug_mode == 5) { return face_model * 0.5 + 0.5; }
	return lit + pal.rgb * pal.a;
}

void fragment() {
	float G = float(grid_size);
	vec3 cam = v_cam_model;
	vec3 dir = normalize(v_model - cam);
	dir = mix(dir, vec3(1e-6), lessThan(abs(dir), vec3(1e-6)));
	vec3 sun = normalize(light_dir);

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

	vec3 p0 = (cam + dir * t_start + 0.5) * G + dir * 1e-3;
	float t_box_exit = (t_exit - t_start) * G;
	ivec3 cell = clamp(ivec3(floor(p0)), ivec3(0), ivec3(grid_size - 1));

	ivec3 step_dir = ivec3(sign(dir));
	vec3 pos_step = vec3(greaterThan(dir, vec3(0.0)));
	vec3 t_delta = abs(inv);
	vec3 t_max = (vec3(cell) + pos_step - p0) * inv;

	int axis = (t_near3.x > t_near3.y) ? ((t_near3.x > t_near3.z) ? 0 : 2) : ((t_near3.y > t_near3.z) ? 1 : 2);
	float t = 0.0;

	vec3 trans = vec3(1.0);
	vec3 emitted = vec3(0.0);
	float t_first = -1.0;
	bool hit_solid = false;
	float t_hit = 0.0;
	uvec4 value = uvec4(0u);

	bool in_liquid = false;
	bool prev_liquid = false;
	float t_in = 0.0;
	vec3 liquid_col = vec3(0.0);
	vec3 liquid_shade = hemi_light(vec3(0.0, 1.0, 0.0)) * 0.9 + sun_color * 0.35;
	vec4 f_prev = field(p0);
	float t_prev = 0.0;
	{
		uint id0 = voxel_at(cell).x;
		if (is_liquid(id0) && f_prev.r >= 0.5) {
			in_liquid = true;
			liquid_col = palette[int(id0)].rgb;
		}
		if (is_opaque(id0) && f_prev.g >= 0.5) {
			hit_solid = true; // camera is inside a solid
			value = voxel_at(cell);
		}
	}

	int max_steps = grid_size * 3;
	for (int i = 0; i < max_steps && !hit_solid; i++) {
		if (brick_empty(cell) && !in_liquid && !prev_liquid) {
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
			f_prev = vec4(0.0);
			t_prev = t;
			continue;
		}
		value = voxel_at(cell);
		uint id = value.x;
		float t_next = min(t_max.x, min(t_max.y, t_max.z));
		bool liquid = is_liquid(id);
		vec4 f = field(p0 + dir * t_next);

		// Opaque isosurface crossing inside this cell.
		if (f.g >= 0.5 && f_prev.g < 0.5) {
			t_hit = bisect(p0, dir, t_prev, t_next, 1, true);
			hit_solid = true;
			break;
		}

		if (id != 0u && !liquid && is_gas(id)) {
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
			if (!in_liquid && f.r >= 0.5) {
				float ts = bisect(p0, dir, t_prev, t_next, 0, true);
				vec3 ps = p0 + dir * ts;
				float lap;
				vec3 n = -normalize(field_gradient(ps, 0, 0.5, lap) + vec3(1e-6));
				vec3 n_world = normalize(mat3(MODEL_MATRIX) * n);
				float cos_i = max(dot(-dir, n), 0.0);
				float fresnel = liquid_f0 + (1.0 - liquid_f0) * pow(1.0 - cos_i, 5.0);
				vec3 refl_world = normalize(mat3(MODEL_MATRIX) * reflect(dir, n));
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
			} else if (in_liquid && f.r < 0.5) {
				float ts = bisect(p0, dir, t_prev, t_next, 0, false);
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
		vec3 ps = p0 + dir * t_hit;
		if (in_liquid) {
			float len = max(t_hit - t_in, 0.0);
			emitted += trans * liquid_col * liquid_shade * (1.0 - exp(-scatter * len));
			trans *= exp(-absorb * len);
		}
		// Which element: the opaque voxel just behind the surface, else the DDA cell.
		// A wide stencil averages over the voxel stairs of the smoothed surface.
		float lap;
		vec3 grad = field_gradient(ps, 1, 1.0, lap);
		vec3 n_model = -normalize(grad + vec3(1e-6));
		vec3 n_coarse = -normalize(field_gradient_coarse(ps, 1.0, 2.0) + vec3(1e-6));
		if (dot(n_coarse, n_model) > 0.0) {
			n_model = normalize(mix(n_model, n_coarse, 0.75));
		}
		ivec3 behind = ivec3(floor(ps - n_model * 0.6));
		uvec4 hv = outside(behind) ? value : voxel_at(behind);
		if (!is_opaque(hv.x)) {
			ivec3 ahead = ivec3(floor(ps + dir * 0.5));
			hv = outside(ahead) ? value : voxel_at(ahead);
		}
		if (!is_opaque(hv.x)) {
			hv = value;
		}
		uint id = is_opaque(hv.x) ? hv.x : 1u;
		float seed = float(hv.y) / 255.0;
		vec3 face_model = vec3(0.0);
		face_model[axis] = -float(step_dir[axis]);
		if (t_hit == 0.0) {
			face_model = -dir;
			n_model = -dir;
		}
		vec3 hit_model = cam + dir * (t_start + t_hit / G);
		vec4 hit_view = VIEW_MATRIX * MODEL_MATRIX * vec4(hit_model, 1.0);
		vec3 lit = shade_opaque(ps, n_model, face_model, id, seed, -hit_view.z, VIEWPORT_SIZE, PROJECTION_MATRIX[1][1],
			mat3(MODEL_MATRIX), (cam + 0.5) * G);
		// Curvature: concave points read darker, ridges lighter (smooth materials only;
		// on crisp walls the step field would band per voxel).
		lit *= 1.0 - clamp(lap * 0.5, -0.12, 0.12) * mat_smooth[int(id)];
		emitted += trans * lit;
		trans = vec3(0.0);
		t_depth = (t_first >= 0.0) ? t_first : t_hit;
	} else {
		if (in_liquid) {
			float len = max(t_box_exit - t_in, 0.0);
			emitted += trans * liquid_col * liquid_shade * (1.0 - exp(-scatter * len));
			trans *= exp(-absorb * len);
		}
		if (t_first < 0.0 && max(trans.r, max(trans.g, trans.b)) > 0.995) {
			DEPTH = 0.0;
			discard;
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
