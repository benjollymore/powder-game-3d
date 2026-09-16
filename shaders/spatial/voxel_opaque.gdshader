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
uniform int mat_layer[32];
uniform sampler3D physical_overflow : filter_nearest, repeat_disable;
uniform int powder_mask = 0;
uniform int leafy_mask = 0;

bool coarse_physical(ivec3 cell, uvec4 value, bvec2 fallback) {
	if (fallback.y && (leafy_mask & (1 << int(value.x))) != 0) { return true; }
	if (fallback.x && (powder_mask & (1 << int(value.x))) != 0 && ((value.w >> 1u) & 3u) != 0u && cell.y > 0) {
		uint below = voxel_at(cell - ivec3(0, 1, 0)).x;
		return below == 0u || is_gas(below);
	}
	return false;
}
uniform float mat_smooth[32];
uniform float mat_grain[32];
uniform float mat_rough[32];
uniform float texture_tile = 16.0;
uniform float texture_size = 256.0;
uniform float ao_strength = 1.0;
// Discovery control: zero removes decorative texture/grain work while preserving geometry.
uniform float detail_strength : hint_range(0.0, 1.0) = 1.0;
// Simulation seconds; animates the underwater caustic pattern.
uniform float sim_time = 0.0;
uniform float caustic_strength = 1.0;
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
	bvec2 fallback = greaterThan(texelFetch(physical_overflow, ivec3(0), 0).rg, vec2(0.5));
	bool coarse_hit = false;
	bool hit = false;
	float t_hit = 0.0;
	uvec4 value = uvec4(0u);
	float g_prev = field(r.p0).g;
	float t_prev = 0.0;
	{
		uint id0 = voxel_at(r.cell).x;
		coarse_hit = any(fallback) && coarse_physical(r.cell, voxel_at(r.cell), fallback);
		if (coarse_hit || (is_opaque(id0) && g_prev >= 0.5)) {
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
		if (any(fallback) && coarse_physical(r.cell, voxel_at(r.cell), fallback)) {
			coarse_hit = true;
			hit = true;
			t_hit = t;
			value = voxel_at(r.cell);
			break;
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
	vec3 n_fine = -normalize(grad + vec3(1e-6));
	vec3 n_coarse = -normalize(field_gradient_coarse(ps, 1.0, 2.0) + vec3(1e-6));
	// Cell selection (which element/seed shades this hit) keeps the previous
	// 25/75 blend so material identity and per-cell seed jitter are unchanged
	// for every material, including crisp walls.
	vec3 n_model = n_fine;
	if (dot(n_coarse, n_fine) > 0.0) {
		n_model = normalize(mix(n_fine, n_coarse, 0.75));
	}
	// Smoothed materials take their shading shape from the lattice-free
	// coarse mips only. The one-cell gradient and Laplacian of a smoothed
	// heap oscillate with the voxel lattice on every planar slope: the
	// cell-scale share of the old blend and the level-0 curvature darkening
	// drew rings on sand cones. Geometry (hit position) is unchanged.
	vec3 n_wide = -normalize(field_gradient_coarse(ps, 2.0, 4.0) + vec3(1e-6));
	vec3 n_smooth = normalize(mix(n_coarse, n_wide, dot(n_coarse, n_wide) > 0.0 ? 0.75 : 0.0));
	if (dot(n_smooth, n_fine) <= 0.0) {
		n_smooth = n_fine;
	}
	float lap_smooth = field_laplacian_coarse(ps, 1.0, 2.0);
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
	if (coarse_hit) { hv = value; }
	uint id = is_opaque(hv.x) ? hv.x : 1u;
	float seed = float(hv.y) / 255.0;
	// A bisected density hit is approximate: selecting the nearest integer
	// plane can choose a tangential cell boundary and produce dark speckles
	// across a perfectly flat wall. The local density gradient identifies the
	// physical surface orientation independently of the hit-position error.
	vec3 grad_abs = abs(grad);
	int hit_axis = (grad_abs.x > grad_abs.y && grad_abs.x > grad_abs.z) ? 0 : ((grad_abs.y > grad_abs.z) ? 1 : 2);
	vec3 face_model = vec3(0.0);
	face_model[hit_axis] = -sign(grad[hit_axis]);
	if (coarse_hit) {
		face_model = vec3(0.0);
		face_model[r.axis] = -float(r.step_dir[r.axis]);
		n_model = face_model;
		n_smooth = face_model;
	}
	if (t_hit == 0.0) {
		// Entering a clipped volume creates an axis-aligned cap. Ray-facing
		// normals made that flat cross-section shade like a curved surface.
		if (r.t_enter >= 0.0) {
			face_model = vec3(0.0);
			face_model[r.axis] = -float(r.step_dir[r.axis]);
		} else {
			// Preserve the existing fallback for a camera embedded in material;
			// there is no entry face between the camera and the sample.
			face_model = -r.dir;
		}
		// Both overrides must also replace the smoothed shading normal: inside
		// a heap the field is uniform, its coarse gradients vanish, and the
		// normalized epsilon would light every cap as one constant diagonal.
		n_model = face_model;
		n_smooth = face_model;
	}

	mat3 model_basis = mat3(MODEL_MATRIX);
	float sm = mat_smooth[int(id)];
	vec3 n = normalize(mix(face_model, n_smooth, sm));
	vec3 n_geo = n; // before texture and grain perturbation: AO and shadow taps
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
	vec3 tex = vec3(0.5);
	vec4 pal = palette[int(id)];
	vec3 base = pal.rgb;
	if (detail_strength > 0.001) {
		tex = triplanar(albedo_maps, ps, bw, layer, lod);
		vec3 tn = triplanar(normal_maps, ps, bw, layer, lod) * 2.0 - 1.0;
		vec3 pert = bw.x * vec3(0.0, tn.x, tn.y) + bw.y * vec3(tn.x, 0.0, tn.y) + bw.z * vec3(tn.x, tn.y, 0.0);
		vec3 gn = texture(grain_noise, ps / 8.0).rgb * 2.0 - 1.0;
		n = normalize(n + detail_strength * (pert * 0.6 + gn * mat_grain[int(id)]));
		base *= mix(1.0, (0.94 + 0.12 * seed), detail_strength);
		base *= mix(vec3(1.0), 0.55 + 0.9 * tex, detail_strength);
		base *= 1.0 - clamp(lap_smooth * 0.5, -0.12, 0.12) * sm * detail_strength;
	}

	float ao = 1.0;
	ao -= 0.35 * field_g(ps + n_geo * 1.5, 0.0);
	ao -= 0.25 * field_g(ps + n_geo * 3.0, 1.0);
	ao -= 0.2 * field_g(ps + n_geo * 6.0, 2.0);
	ao -= 0.1 * field_g(ps + n_geo * 12.0, 3.0);
	ao -= 0.15 * field_g(ps + vec3(0.0, 8.0, 0.0), 2.0);
	ao = mix(1.0, clamp(ao, 0.15, 1.0), ao_strength);

	vec3 to_sun_model = normalize(light_dir); // uniform scale: world and model directions agree
	v_sunvis = sun_vis(ps + n_geo * 0.75 + to_sun_model * 1.25);
	// Under liquid: sunlight arrives through a moving surface, so modulate it
	// with two drifting octaves of noise projected along the sun and tint it.
	ivec3 above = ivec3(floor(ps + n_geo * 1.0));
	if (!outside(above) && is_liquid(voxel_at(above).x)) {
		// An opaque liquid (lava) casts no sunlit ripples onto what it covers:
		// the ripple strength falls off exponentially with opacity above water's
		// 1.0 (exp(0) is exactly 1, so water keeps its bytes; 12 leaves 0.4%).
		// Caustics are sunlight focused by the surface overhead onto what lies
		// below, so their strength follows the receiver's cosine like any other
		// irradiance. Without that term a vertical face got the full pattern,
		// and because the pattern is sampled by world xz after projecting along
		// the sun, every point of such a face walks the same straight line
		// through the noise: the two-dimensional ripple collapsed into stripes
		// at the voxel staircase. A submerged wall now takes almost none, a
		// floor takes it all, and the bright bars Ben saw on submerged stone
		// and on wax seen from underwater are gone.
		float facing = max(dot(n_geo, to_sun_model), 0.0);
		float clarity = caustic_strength * facing * exp(-0.5 * (max(liquid_opacity[int(voxel_at(above).x)], 1.0) - 1.0));
		vec3 q = ps - to_sun_model * (ps.y / max(abs(to_sun_model.y), 0.3));
		float c1 = texture(grain_noise, vec3(q.xz / 9.0, sim_time * 0.35)).r;
		float c2 = texture(grain_noise, vec3(q.xz / 6.5 + 3.7, 5.0 - sim_time * 0.27)).g;
		float c = smoothstep(0.4, 0.65, c1) * smoothstep(0.4, 0.65, c2);
		v_sunvis *= mix(1.0, 0.6 + 2.6 * c, clarity);
		base *= mix(vec3(1.0), vec3(0.8, 0.92, 1.0), 0.6 * clarity);
	}

	vec3 n_world = normalize(model_basis * n);
	NORMAL = normalize((VIEW_MATRIX * vec4(n_world, 0.0)).xyz);
	ALBEDO = base;
	ROUGHNESS = mat_rough[int(id)];
	METALLIC = 0.0;
	AO = ao;
	// Palette alpha is self-illumination. On textured materials the light comes
	// from the dark cracks of the texture (a cooling crust); zero for every
	// element without an emission entry, so existing looks are unchanged.
	float crack = 1.0 - smoothstep(0.35, 0.75, dot(tex, vec3(1.0 / 3.0)));
	EMISSION = pal.rgb * pal.a * mix(1.0, 0.25 + 0.75 * crack, detail_strength);
	EMISSION += thermal_emission(ivec3(floor(ps - n_geo * 0.5)));
	AO_LIGHT_AFFECT = 0.0;
	LIGHT_VERTEX = hit_view.xyz;
	vec4 hit_clip = PROJECTION_MATRIX * hit_view;
	DEPTH = hit_clip.z / hit_clip.w;

	if (debug_mode == 1) { ALBEDO = pal.rgb; ROUGHNESS = 1.0; }
	if (debug_mode == 2) { ALBEDO = vec3(ao); EMISSION = vec3(ao); }
	if (debug_mode == 3) { ALBEDO = vec3(0.0); EMISSION = n * 0.5 + 0.5; }
	if (debug_mode == 4) { ALBEDO = vec3(0.0); EMISSION = tex; }
	if (debug_mode == 5) { ALBEDO = vec3(0.0); EMISSION = vec3(v_sunvis); }
	if (debug_mode == 6) { ALBEDO = vec3(0.0); EMISSION = vec3(field_g(ps + n_geo * 1.5, 0.0), field_g(ps + n_geo * 3.0, 1.0), field_g(ps + n_geo * 6.0, 2.0)); }
	if (debug_mode == 7) { ALBEDO = vec3(0.0); EMISSION = fract(ps); }
	if (debug_mode == 8) { ALBEDO = vec3(0.0); EMISSION = n_geo * 0.5 + 0.5; }
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
