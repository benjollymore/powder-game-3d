// Raymarches the voxel world stored in an RGBA8 3D texture (R = element id,
// G = per-voxel seed, B/A reserved), all sampled as exact bytes.
// Drawn on a unit cube (model space [-0.5, 0.5]^3). Back faces are rendered so
// the camera can be inside the box. Writes DEPTH so ordinary meshes and the
// brush gizmo depth-test correctly against the voxels.
shader_type spatial;
render_mode cull_front, unshaded;

uniform sampler3D voxels : filter_nearest, repeat_disable;
uniform vec4 palette[16];
uniform int grid_size = 128;
uniform vec3 light_dir = vec3(0.4, 1.0, 0.3);
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.9);
uniform vec3 sky_color : source_color = vec3(0.74, 0.79, 0.84);
uniform vec3 ground_color : source_color = vec3(0.82, 0.84, 0.86);
uniform float ambient = 0.38;

varying vec3 v_model;
varying vec3 v_cam_model;

void vertex() {
	v_model = VERTEX;
	// Per-vertex (identical at every vertex) so the fragment stage skips the inverse.
	v_cam_model = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

// Returns the voxel as bytes: x = element id, y = seed, z/w reserved.
uvec4 voxel_at(ivec3 cell) {
	return uvec4(texelFetch(voxels, cell, 0) * 255.0 + 0.5);
}

void fragment() {
	float G = float(grid_size);
	vec3 cam = v_cam_model;
	vec3 dir = normalize(v_model - cam);

	// Ray vs. the unit box (slab test). inv may be +-inf on axis-aligned rays; min/max cope.
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

	// Entry point in voxel space [0, G]^3, nudged inside.
	vec3 p = (cam + dir * t_start + 0.5) * G;
	p += dir * 1e-3;
	ivec3 cell = clamp(ivec3(floor(p)), ivec3(0), ivec3(grid_size - 1));

	// Amanatides-Woo setup, t measured in voxel units along dir.
	ivec3 step_dir = ivec3(sign(dir));
	vec3 t_delta = abs(inv);
	vec3 boundary = vec3(cell) + max(vec3(step_dir), vec3(0.0));
	vec3 t_max = (boundary - p) * inv;

	// Face we entered through (used if the very first voxel is solid).
	int axis = (t_near3.x > t_near3.y) ? ((t_near3.x > t_near3.z) ? 0 : 2) : ((t_near3.y > t_near3.z) ? 1 : 2);
	float t_hit = 0.0;
	bool hit = false;
	uvec4 value = uvec4(0u);

	int max_steps = grid_size * 3;
	for (int i = 0; i < max_steps; i++) {
		value = voxel_at(cell);
		if (value.x != 0u) {
			hit = true;
			break;
		}
		if (t_max.x < t_max.y && t_max.x < t_max.z) {
			cell.x += step_dir.x; t_hit = t_max.x; t_max.x += t_delta.x; axis = 0;
		} else if (t_max.y < t_max.z) {
			cell.y += step_dir.y; t_hit = t_max.y; t_max.y += t_delta.y; axis = 1;
		} else {
			cell.z += step_dir.z; t_hit = t_max.z; t_max.z += t_delta.z; axis = 2;
		}
		if (any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(grid_size)))) {
			break;
		}
	}

	if (!hit) {
		DEPTH = 0.0;
		discard;
	}

	uint id = value.x;
	float seed = float(value.y) / 255.0;

	vec3 normal_model = vec3(0.0);
	normal_model[axis] = -float(step_dir[axis]);
	if (t_enter < 0.0 && t_hit == 0.0) {
		normal_model = -dir; // camera is inside a solid voxel
	}
	vec3 normal_world = normalize(mat3(MODEL_MATRIX) * normal_model);

	vec3 hit_model = cam + dir * (t_start + t_hit / G);
	vec4 hit_view = VIEW_MATRIX * MODEL_MATRIX * vec4(hit_model, 1.0);
	vec4 hit_clip = PROJECTION_MATRIX * hit_view;
	DEPTH = hit_clip.z / hit_clip.w;

	vec4 pal = palette[int(id)];
	vec3 base = pal.rgb * (0.88 + 0.16 * seed);
	float diffuse = max(dot(normal_world, normalize(light_dir)), 0.0);
	// Hemisphere ambient: sky from above, ground bounce from below.
	vec3 hemi = mix(ground_color, sky_color, normal_world.y * 0.5 + 0.5);
	// Subtle per-face tint keeps cube edges readable in flat light.
	float face_tint = 0.9 + 0.1 * abs(normal_model.y) + 0.04 * abs(normal_model.x);
	vec3 lit = base * face_tint * (hemi * ambient + sun_color * diffuse * (1.0 - ambient * 0.5));
	// Palette alpha is emission strength; values above the glow threshold bloom.
	ALBEDO = lit + pal.rgb * pal.a;
}
