#[compute]
#version 450

// Paints a brush (modes 0-2) or an axis-aligned box (mode 3, 4) of one
// element into the voxel world, or heats / cools a sphere (modes 5, 6) in the
// thermal layer without touching voxel bytes. Dispatched over the bounding
// box; one thread per voxel. Box mode is how scenarios are built on the GPU.
//
// Brush shape (docs/milestone/placement-brief.md contract 5), carried in
// box_hi.x for the non-box modes, whose box corner words are otherwise unused:
// 0 sphere (ball of radius r), 1 cube ([c - r, c + r] on every axis),
// 2 disc (one-cell-thick square of half-width r on the plane whose axis is
// box_hi.y). Heat and cool keep the sphere with its radial falloff.
//
// Painted material starts at its element's initial temperature with no latent
// progress (an external source, docs/milestone/heat-brief.md contract 5);
// erased cells keep their temperature, as the air left behind inherits it.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

layout(rgba8, set = 0, binding = 0) uniform restrict image3D grid;
layout(rg32f, set = 0, binding = 1) uniform restrict image3D thermal;
#include "elem.glslinc"
layout(std430, set = 0, binding = 2) restrict readonly buffer Elems { Elem elems[]; };
// Per-stroke "written" mask: cells this stroke stamped. The surface pick treats
// them as air so a stroke never re-targets its own cap. Cleared when a stroke
// begins and ends; only stroke stamps (box_hi.z != 0) set it.
layout(r8, set = 0, binding = 3) uniform restrict image3D stroke_mask;

layout(push_constant, std430) uniform Params {
	ivec4 center_radius;      // sphere: cx, cy, cz, radius (voxels); box: lo xyz, unused
	uvec4 element_mode_seed;  // element id, mode (0 replace, 1 only into air, 2 erase, 3 box, 4 box only air, 5 heat, 6 cool, 7 box erase), seed, liquid amount
	ivec4 box_hi;             // box: exclusive upper corner; brush: x = shape, y = disc axis, z = mark stroke mask; heat/cool: w = strength in kelvin (float bits)
} pc;

layout(constant_id = 0) const int GRID = 128;
const uint MODE_ERASE = 2u;
const uint MODE_HEAT = 5u;
const uint MODE_COOL = 6u;
const uint MODE_BOX_ERASE = 7u;
const int SHAPE_SPHERE = 0;
const int SHAPE_CUBE = 1;
const int SHAPE_DISC = 2;

uint hash(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

void main() {
	uint mode = pc.element_mode_seed.y;
	bool box = (mode == 3u || mode == 4u || mode == MODE_BOX_ERASE);
	bool erasing = (mode == MODE_ERASE || mode == MODE_BOX_ERASE);
	ivec3 lo = box ? pc.center_radius.xyz : pc.center_radius.xyz - ivec3(pc.center_radius.w);
	ivec3 p = lo + ivec3(gl_GlobalInvocationID);
	if (any(lessThan(p, ivec3(0))) || any(greaterThanEqual(p, ivec3(GRID)))) {
		return;
	}
	int d2 = 0;
	if (box) {
		if (any(greaterThanEqual(p, pc.box_hi.xyz))) {
			return;
		}
	} else {
		ivec3 d = p - pc.center_radius.xyz;
		int r = pc.center_radius.w;
		d2 = d.x * d.x + d.y * d.y + d.z * d.z; // dot() is float-only in GLSL
		int shape = (mode == MODE_HEAT || mode == MODE_COOL) ? SHAPE_SPHERE : pc.box_hi.x;
		// The dispatch is rounded up to whole 8-thread groups, so every shape
		// must bound itself to [c - r, c + r]; the undo capture covers exactly
		// that box (EditGPU.capture_stroke) and nothing may write outside it.
		if (any(greaterThan(abs(d), ivec3(r)))) {
			return;
		}
		if (shape == SHAPE_CUBE) {
			// Everything inside the bound box.
		} else if (shape == SHAPE_DISC) {
			int axis = clamp(pc.box_hi.y, 0, 2);
			if (d[axis] != 0) {
				return;
			}
		} else if (d2 > r * r) {
			return;
		}
	}
	if (mode == MODE_HEAT || mode == MODE_COOL) {
		// Radial falloff (R^2 - d^2) / R^2 with R = radius + 1, so the centre
		// gets the full strength and the rim about a third of it. The
		// division is exact whenever R^2 is a power of two, so heat followed
		// by an equal cool restores the previous bytes exactly at radius 3.
		int R = pc.center_radius.w + 1;
		float weight = float(R * R - d2) / float(R * R);
		float strength = intBitsToFloat(pc.box_hi.w) * weight;
		vec2 tg = imageLoad(thermal, p).rg;
		tg.x = (mode == MODE_HEAT) ? tg.x + strength : max(tg.x - strength, 1.0);
		imageStore(thermal, p, vec4(tg, 0.0, 0.0));
		return;
	}
	uint id = pc.element_mode_seed.x;
	if (erasing) {
		// Erase changes only occupied cells: air keeps its seed and latent
		// state, so the ghost preview's occupied-cell set is exactly the set
		// of cells whose bytes change.
		uvec4 cur = uvec4(imageLoad(grid, p) * 255.0 + 0.5);
		if (cur.x == 0u) {
			return;
		}
		id = 0u;
	} else if (mode == 1u || mode == 4u) {
		uvec4 cur = uvec4(imageLoad(grid, p) * 255.0 + 0.5);
		if (cur.x != 0u) {
			return;
		}
	}
	uint seed = hash(uint(p.x) * 73856093u ^ uint(p.y) * 19349663u ^ uint(p.z) * 83492791u
			^ pc.element_mode_seed.z) & 0xFFu;
	uint amount = erasing ? 0u : pc.element_mode_seed.w;
	imageStore(grid, p, vec4(uvec4(id, seed, amount, 0u)) / 255.0);
	if (!box && pc.box_hi.z != 0) {
		imageStore(stroke_mask, p, vec4(1.0));
	}
	if (erasing) {
		vec2 tg = imageLoad(thermal, p).rg;
		imageStore(thermal, p, vec4(tg.x, 0.0, 0.0, 0.0));
	} else {
		imageStore(thermal, p, vec4(ELEM_INITIAL_TEMP(elems[id]), 0.0, 0.0, 0.0));
	}
}
