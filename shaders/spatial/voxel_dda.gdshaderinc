// Shared uniforms and helpers for the two voxel raymarch passes
// (voxel_opaque.gdshader and voxel_volume.gdshader).
//
// Voxel texture bytes: R element id, G seed, B liquid amount, A flags.
// Fields texture: R liquid density, G smoothed opaque density, B gas, + mips.
// Sunvis: fraction of sunlight reaching each voxel.

uniform sampler3D voxels : filter_nearest, repeat_disable;
uniform sampler3D occupancy : filter_nearest, repeat_disable;
uniform sampler3D fields : filter_linear_mipmap, repeat_disable;
uniform sampler3D sunvis : filter_linear, repeat_disable;
uniform vec4 palette[16];
uniform int grid_size = 128;
uniform int brick_size = 8;
uniform int liquid_mask = 0;
uniform int gas_mask = 0;
// Non-destructive discovery section: remove the positive side visually only.
uniform bool section_enabled = false;
uniform int section_axis = 2;
uniform int section_cell = 127;
uniform vec3 light_dir = vec3(0.4, 1.0, 0.3); // toward the sun, world space
uniform vec3 sun_color : source_color = vec3(1.0, 0.96, 0.9);
uniform vec3 sky_color : source_color = vec3(0.74, 0.79, 0.84);
uniform vec3 ground_color : source_color = vec3(0.82, 0.84, 0.86);

varying vec3 v_model;
varying vec3 v_cam_model;

uvec4 voxel_at(ivec3 cell) {
	return uvec4(texelFetch(voxels, cell, 0) * 255.0 + 0.5);
}

// channel 0: any solid/powder in the brick; channel 1: any liquid/gas.
bool brick_empty(ivec3 cell, int channel) {
	vec4 occ = texelFetch(occupancy, cell / brick_size, 0);
	return ((channel == 0) ? occ.r : occ.g) < 0.5;
}

bool outside(ivec3 cell) {
	return any(lessThan(cell, ivec3(0))) || any(greaterThanEqual(cell, ivec3(grid_size))) || (section_enabled && cell[section_axis] > section_cell);
}

bool is_liquid(uint id) { return (liquid_mask & (1 << int(id))) != 0; }
bool is_gas(uint id) { return (gas_mask & (1 << int(id))) != 0; }
bool is_opaque(uint id) { return id != 0u && !is_liquid(id) && !is_gas(id); }

vec4 field(vec3 p) { return textureLod(fields, p / float(grid_size), 0.0); }
float field_g(vec3 p, float lod) { return textureLod(fields, p / float(grid_size), lod).g; }
float sun_vis(vec3 p) { return textureLod(sunvis, p / float(grid_size), 0.0).r; }

vec3 hemi_light(vec3 n) {
	return mix(ground_color, sky_color, n.y * 0.5 + 0.5);
}

// Crossing of a field channel with 0.5 between ta and tb along the ray.
float bisect(vec3 p0, vec3 dir, float ta, float tb, int ch, bool rising) {
	for (int k = 0; k < 4; k++) {
		float tm = 0.5 * (ta + tb);
		vec4 f = field(p0 + dir * tm);
		float d = (ch == 0) ? f.r : f.g;
		bool above = d >= 0.5;
		if (above == rising) { tb = tm; } else { ta = tm; }
	}
	return tb;
}

vec3 field_gradient(vec3 p, int ch, float e, out float lap) {
	vec4 fc = field(p);
	float c = (ch == 0) ? fc.r : fc.g;
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

vec3 field_gradient_coarse(vec3 p, float lod, float e) {
	vec3 gp = vec3(field_g(p + vec3(e, 0, 0), lod), field_g(p + vec3(0, e, 0), lod), field_g(p + vec3(0, 0, e), lod));
	vec3 gm = vec3(field_g(p - vec3(e, 0, 0), lod), field_g(p - vec3(0, e, 0), lod), field_g(p - vec3(0, 0, e), lod));
	return gp - gm;
}

// Opaque-density Laplacian at a mip level, scaled to per-cell^2 units so
// different (lod, e) stencils are comparable. Smoothed powders read shape
// above the voxel lattice; the level-0 stencil rings on every planar heap.
float field_laplacian_coarse(vec3 p, float lod, float e) {
	float c = field_g(p, lod);
	float sum = field_g(p + vec3(e, 0, 0), lod) + field_g(p - vec3(e, 0, 0), lod)
		+ field_g(p + vec3(0, e, 0), lod) + field_g(p - vec3(0, e, 0), lod)
		+ field_g(p + vec3(0, 0, e), lod) + field_g(p - vec3(0, 0, e), lod);
	return (sum - 6.0 * c) / (e * e);
}

// Ray setup shared by both passes. Returns false if the ray misses the box.
struct Ray {
	vec3 cam;      // camera in model space
	vec3 dir;      // model space, normalised
	vec3 inv;
	float t_start; // model units along dir to the entry point
	float t_box;   // voxel units from entry to exit
	vec3 p0;       // entry point in voxel space
	ivec3 cell;
	ivec3 step_dir;
	vec3 pos_step;
	vec3 t_delta;
	vec3 t_max;
	int axis;
	float t_enter;
};

bool setup_ray(vec3 model_pos, vec3 cam_model, out Ray r) {
	float G = float(grid_size);
	r.cam = cam_model;
	vec3 dir = normalize(model_pos - cam_model);
	dir = mix(dir, vec3(1e-6), lessThan(abs(dir), vec3(1e-6)));
	r.dir = dir;
	r.inv = 1.0 / dir;
	vec3 t_lo = (vec3(-0.5) - cam_model) * r.inv;
	vec3 hi = vec3(0.5);
	if (section_enabled) {
		hi[section_axis] = float(section_cell + 1) / G - 0.5;
	}
	vec3 t_hi = (hi - cam_model) * r.inv;
	vec3 t_near3 = min(t_lo, t_hi);
	vec3 t_far3 = max(t_lo, t_hi);
	r.t_enter = max(max(t_near3.x, t_near3.y), t_near3.z);
	float t_exit = min(min(t_far3.x, t_far3.y), t_far3.z);
	r.t_start = max(r.t_enter, 0.0);
	if (t_exit <= r.t_start) {
		return false;
	}
	r.p0 = (cam_model + dir * r.t_start + 0.5) * G + dir * 1e-3;
	r.t_box = (t_exit - r.t_start) * G;
	r.cell = clamp(ivec3(floor(r.p0)), ivec3(0), ivec3(grid_size - 1));
	r.step_dir = ivec3(sign(dir));
	r.pos_step = vec3(greaterThan(dir, vec3(0.0)));
	r.t_delta = abs(r.inv);
	r.t_max = (vec3(r.cell) + r.pos_step - r.p0) * r.inv;
	r.axis = (t_near3.x > t_near3.y) ? ((t_near3.x > t_near3.z) ? 0 : 2) : ((t_near3.y > t_near3.z) ? 1 : 2);
	return true;
}

// Leap to the exit of the current (empty) brick. Returns false when the ray leaves the box.
bool leap_brick(inout Ray r, inout float t) {
	ivec3 bmin = (r.cell / brick_size) * brick_size;
	vec3 planes = vec3(bmin) + r.pos_step * float(brick_size);
	vec3 tb = (planes - r.p0) * r.inv;
	t = min(tb.x, min(tb.y, tb.z));
	r.axis = (tb.x <= tb.y && tb.x <= tb.z) ? 0 : ((tb.y <= tb.z) ? 1 : 2);
	r.cell = ivec3(floor(r.p0 + r.dir * (t + 1e-3)));
	r.cell[r.axis] = (r.step_dir[r.axis] > 0) ? bmin[r.axis] + brick_size : bmin[r.axis] - 1;
	if (outside(r.cell)) {
		return false;
	}
	r.t_max = (vec3(r.cell) + r.pos_step - r.p0) * r.inv;
	return true;
}

// Advance one voxel. Returns false when the ray leaves the box.
bool step_voxel(inout Ray r, inout float t) {
	if (r.t_max.x < r.t_max.y && r.t_max.x < r.t_max.z) {
		r.cell.x += r.step_dir.x; t = r.t_max.x; r.t_max.x += r.t_delta.x; r.axis = 0;
	} else if (r.t_max.y < r.t_max.z) {
		r.cell.y += r.step_dir.y; t = r.t_max.y; r.t_max.y += r.t_delta.y; r.axis = 1;
	} else {
		r.cell.z += r.step_dir.z; t = r.t_max.z; r.t_max.z += r.t_delta.z; r.axis = 2;
	}
	return !outside(r.cell);
}
