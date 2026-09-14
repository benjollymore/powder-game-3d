#[compute]
#version 450

// Sun visibility field: for every voxel, how much sunlight reaches it through
// the smoothed opaque field and gas. Swept slab by slab from the sun-facing
// face of the box along the sun's dominant axis: vis(v) = vis(v + step) * T(v),
// where step reaches the previous slab (one voxel toward the sun) with a
// lateral drift, so vis(v + step) is a bilinear read of that slab.
//
// A workgroup owns a 16x16 tile of the slab plane and walks 8 consecutive
// slabs, keeping a haloed copy of the previous slab in shared memory so the
// drift never needs another workgroup's fresh results. Dispatch one call per
// 8-slab block, with a barrier between blocks.

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

layout(r8, set = 0, binding = 0) uniform restrict image3D sunvis;
layout(set = 0, binding = 1) uniform sampler3D fields;

layout(push_constant, std430) uniform Params {
	ivec4 a; // dominant axis (0..2), sign of to-sun along it (+1/-1), first slab of this block, slab count
	vec4 b;  // lateral drift per slab in (u, v), gas extinction per voxel, unused
} pc;

// Size of this field; the fields texture is sampled at the matching mip so a
// half-resolution sweep still sees one-voxel walls as partial occluders.
layout(constant_id = 0) const int GRID = 128;
const float FIELDS_LOD = 1.0;

const int TILE = 16;
const int HALO = 6;
const int W = TILE + 2 * HALO;

shared float prev_slab[W * W];
shared float cur_slab[W * W];

// Slab k counts from the sun-facing face inward.
ivec3 to_voxel(int u, int v, int k) {
	int c = (pc.a.y > 0) ? (GRID - 1 - k) : k;
	if (pc.a.x == 0) { return ivec3(c, u, v); }
	if (pc.a.x == 1) { return ivec3(u, c, v); }
	return ivec3(u, v, c);
}

float transmittance(ivec3 p) {
	vec4 f = textureLod(fields, (vec3(p) + 0.5) / float(GRID), FIELDS_LOD);
	// Two voxels per cell: light crosses both, so square the per-voxel terms.
	float solid = 1.0 - f.g;
	return solid * solid * exp(-2.0 * f.b * pc.b.z);
}

float prev_at(int lu, int lv) {
	lu = clamp(lu, 0, W - 1);
	lv = clamp(lv, 0, W - 1);
	return prev_slab[lu + W * lv];
}

float prev_bilinear(float fu, float fv) {
	int iu = int(floor(fu));
	int iv = int(floor(fv));
	float tu = fu - float(iu);
	float tv = fv - float(iv);
	float a = mix(prev_at(iu, iv), prev_at(iu + 1, iv), tu);
	float b = mix(prev_at(iu, iv + 1), prev_at(iu + 1, iv + 1), tu);
	return mix(a, b, tv);
}

void main() {
	ivec2 origin = ivec2(gl_WorkGroupID.xy) * TILE - HALO;
	int k0 = pc.a.z;
	uint lid = gl_LocalInvocationIndex;

	for (uint i = lid; i < uint(W * W); i += 256u) {
		int u = origin.x + int(i) % W;
		int v = origin.y + int(i) / W;
		float val = 1.0;
		if (k0 > 0 && u >= 0 && v >= 0 && u < GRID && v < GRID) {
			val = imageLoad(sunvis, to_voxel(u, v, k0 - 1)).r;
		}
		prev_slab[i] = val;
	}
	barrier();

	for (int s = 0; s < pc.a.w; s++) {
		int k = k0 + s;
		for (uint i = lid; i < uint(W * W); i += 256u) {
			int lu = int(i) % W;
			int lv = int(i) / W;
			int u = origin.x + lu;
			int v = origin.y + lv;
			float val = 1.0;
			if (u >= 0 && v >= 0 && u < GRID && v < GRID && k < GRID) {
				val = prev_bilinear(float(lu) + pc.b.x, float(lv) + pc.b.y) * transmittance(to_voxel(u, v, k));
				if (lu >= HALO && lu < HALO + TILE && lv >= HALO && lv < HALO + TILE) {
					imageStore(sunvis, to_voxel(u, v, k), vec4(val));
				}
			}
			cur_slab[i] = val;
		}
		barrier();
		for (uint i = lid; i < uint(W * W); i += 256u) {
			prev_slab[i] = cur_slab[i];
		}
		barrier();
	}
}
