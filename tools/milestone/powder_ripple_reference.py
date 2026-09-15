#!/usr/bin/env python3
"""Cell-periodic ripple of the opaque shading terms over a smoothed powder slope.

Dependency-free model of fields.glsl's G channel (3^3 kernel, weights
0.52/0.05/0.0125/0.00375, smoothing 1.0) and of the exact trilinear/mip
sampling voxel_opaque.gdshader performs at the 0.5 isosurface. It advances no
simulation and renders nothing; it only reports how much each shading term
oscillates at the voxel lattice frequency along a planar heap slope, for the
current shader formulas ("baseline") and the smoothed-material candidate.

    python3 tools/milestone/powder_ripple_reference.py [--json path]
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

N = 96          # cells per axis of the model grid
FULL_Y = 60     # heap height at x = 2


def weight(manhattan: int) -> float:
    return (0.52, 0.05, 0.0125, 0.00375)[manhattan]


def occupied(slope: float, x: int, y: int) -> bool:
    return 0 <= x < N and 0 <= y < N and y < FULL_Y + int(math.floor(-(x - 2) * slope)) and x >= 2


def build_field(slope: float) -> list:
    """Texel value per cell: the smoothed density for smoothing 1.0 (z-invariant)."""
    occ = [[1.0 if occupied(slope, x, y) else 0.0 for y in range(N)] for x in range(N)]
    g = [[0.0] * N for _ in range(N)]
    for x in range(N):
        for y in range(N):
            s = 0.0
            for dx in (-1, 0, 1):
                for dy in (-1, 0, 1):
                    for dz in (-1, 0, 1):
                        xx, yy = x + dx, y + dy
                        if 0 <= xx < N and 0 <= yy < N:
                            s += weight(abs(dx) + abs(dy) + abs(dz)) * occ[xx][yy]
            g[x][y] = round(s * 255.0) / 255.0  # RGBA8 quantization
    return g


def mip(field: list, level: int) -> list:
    out = field
    for _ in range(level):
        n = len(out) // 2
        out = [[0.25 * (out[2 * x][2 * y] + out[2 * x + 1][2 * y] + out[2 * x][2 * y + 1] + out[2 * x + 1][2 * y + 1])
                for y in range(n)] for x in range(n)]
    return out


def sample(field: list, px: float, py: float, level: int) -> float:
    """textureLod with linear filtering: texel centres at (i + 0.5) * 2^level."""
    level = int(level)
    scale = float(1 << level)
    n = len(field)
    fx = px / scale - 0.5
    fy = py / scale - 0.5
    x0 = math.floor(fx)
    y0 = math.floor(fy)
    tx = fx - x0
    ty = fy - y0

    def at(i: int, j: int) -> float:
        i = min(max(i, 0), n - 1)
        j = min(max(j, 0), n - 1)
        return field[i][j]

    return ((1 - tx) * (1 - ty) * at(x0, y0) + tx * (1 - ty) * at(x0 + 1, y0)
            + (1 - tx) * ty * at(x0, y0 + 1) + tx * ty * at(x0 + 1, y0 + 1))


def gradient(field: list, px: float, py: float, e: float, level: int) -> tuple:
    gx = sample(field, px + e, py, level) - sample(field, px - e, py, level)
    gy = sample(field, px, py + e, level) - sample(field, px, py - e, level)
    lap = (sample(field, px + e, py, level) + sample(field, px - e, py, level)
           + sample(field, px, py + e, level) + sample(field, px, py - e, level)
           + 2.0 * sample(field, px, py, level)  # the z taps equal the centre for a z-invariant field
           - 6.0 * sample(field, px, py, level))
    return gx, gy, lap


def normalize(v: tuple) -> tuple:
    m = math.hypot(v[0], v[1]) + 1e-9
    return (v[0] / m, v[1] / m)


def hit_y(field: list, px: float) -> float:
    """Vertical probe from above: the 0.5 crossing of the level-0 field."""
    hi, lo = float(N - 2), 0.0
    if sample(field, px, hi, 0) >= 0.5 or sample(field, px, lo, 0) < 0.5:
        return float("nan")
    for _ in range(40):
        mid = 0.5 * (hi + lo)
        if sample(field, px, mid, 0) >= 0.5:
            lo = mid
        else:
            hi = mid
    return hi


def shading_terms(fields: dict, px: float, py: float, candidate: bool) -> dict:
    f0, f1, f2, f3 = fields[0], fields[1], fields[2], fields[3]
    gx, gy, lap = gradient(f0, px, py, 1.0, 0)
    n_fine = normalize((-gx, -gy))
    cgx, cgy, clap = gradient(f1, px, py, 2.0, 1)
    n_coarse = normalize((-cgx, -cgy))
    if candidate:
        # voxel_opaque.gdshader candidate: 25/75 blend of the level-1 (e=2) and
        # level-2 (e=4) gradients, guarded against sign flips; level-1 Laplacian
        # scaled to per-cell^2 units. AO taps are unchanged.
        wgx, wgy, _ = gradient(f2, px, py, 4.0, 2)
        n_wide = normalize((-wgx, -wgy))
        t = 0.75 if n_coarse[0] * n_wide[0] + n_coarse[1] * n_wide[1] > 0.0 else 0.0
        n_smooth = normalize((n_coarse[0] * (1 - t) + n_wide[0] * t, n_coarse[1] * (1 - t) + n_wide[1] * t))
        n = n_smooth if n_smooth[0] * n_fine[0] + n_smooth[1] * n_fine[1] > 0.0 else n_fine
        lap_used = clap / 4.0
    else:
        n = n_fine
        if n_fine[0] * n_coarse[0] + n_fine[1] * n_coarse[1] > 0.0:
            n = normalize((n_fine[0] * 0.25 + n_coarse[0] * 0.75, n_fine[1] * 0.25 + n_coarse[1] * 0.75))
        lap_used = lap
    curvature = 1.0 - min(max(lap_used * 0.5, -0.12), 0.12)
    levels = {0: f0, 1: f1, 2: f2, 3: f3}
    ao = 1.0
    for w, d, lod in zip((0.35, 0.25, 0.2, 0.1), (1.5, 3.0, 6.0, 12.0), (0, 1, 2, 3)):
        ao -= w * sample(levels[lod], px + n[0] * d, py + n[1] * d, lod)
    ao -= 0.15 * sample(f2, px, py + 8.0, 2)
    ao = min(max(ao, 0.15), 1.0)
    return {"normal": n, "curvature": curvature, "ao": ao}


def ripple(values: list, period_samples: int) -> dict:
    """RMS of the residual after a one-lattice-period moving average."""
    half = period_samples // 2
    residual = []
    for i in range(half, len(values) - half):
        window = values[i - half:i + half + 1]
        residual.append(values[i] - sum(window) / len(window))
    rms = math.sqrt(sum(r * r for r in residual) / max(len(residual), 1))
    return {"rms": rms, "peak_to_peak": (max(residual) - min(residual)) if residual else 0.0}


def analyse(slope: float, candidate: bool) -> dict:
    f0 = build_field(slope)
    fields = {0: f0, 1: mip(f0, 1), 2: mip(f0, 2), 3: mip(f0, 3)}
    ideal = normalize((slope, 1.0))
    step = 0.05
    # Mid-slope band only: wide stencils must not reach the plateau or the floor.
    x_lo = 2.0 + (FULL_Y - 48.0) / slope
    x_hi = min(2.0 + (FULL_Y - 12.0) / slope, N - 6.0)
    xs = [x_lo + i * step for i in range(int((x_hi - x_lo) / step))]
    angle, curvature, ao, height = [], [], [], []
    for px in xs:
        py = hit_y(f0, px)
        if math.isnan(py):
            continue
        t = shading_terms(fields, px, py, candidate)
        n = t["normal"]
        # Signed angle from the nominal plane normal. Its mean is not zero on a
        # stepped surface (angles do not average like slopes); only the
        # lattice-periodic residual is the ripple.
        angle.append(math.degrees(math.atan2(n[0], n[1]) - math.atan2(ideal[0], ideal[1])))
        curvature.append(t["curvature"])
        ao.append(t["ao"])
        height.append(py + slope * px)
    # One riser spacing: the longest lattice period on this slope.
    period = int(round((1.0 / step) / slope))
    return {
        "slope_rise_per_cell": slope,
        "variant": "candidate" if candidate else "baseline",
        "samples": len(angle),
        "window_cells": period * step,
        "normal_angle_deg": ripple(angle, period),
        "curvature_factor": ripple(curvature, period),
        "ao": ripple(ao, period),
        "hit_height_cells": ripple(height, period),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", default="docs/milestone/powder-ripple-evidence/reference.json")
    args = parser.parse_args()
    results = []
    for slope in (1.0, 0.6, 0.35):
        for candidate in (False, True):
            row = analyse(slope, candidate)
            results.append(row)
            print("METRIC " + json.dumps(row, sort_keys=True))
    baseline = {r["slope_rise_per_cell"]: r for r in results if r["variant"] == "baseline"}
    candidate = {r["slope_rise_per_cell"]: r for r in results if r["variant"] == "candidate"}
    failures = []
    for slope, b in baseline.items():
        c = candidate[slope]
        for term in ("curvature_factor", "normal_angle_deg"):
            if slope < 1.0 and c[term]["rms"] > 0.5 * b[term]["rms"] + 1e-9:
                failures.append("%s at slope %.2f: candidate rms %.5f vs baseline %.5f" % (term, slope, c[term]["rms"], b[term]["rms"]))
        if c["ao"]["rms"] > b["ao"]["rms"] + 0.002:
            failures.append("ao ripple grew at slope %.2f: %.5f vs %.5f" % (slope, c["ao"]["rms"], b["ao"]["rms"]))
        if abs(c["hit_height_cells"]["rms"] - b["hit_height_cells"]["rms"]) > 1e-12:
            failures.append("hit geometry must be unchanged at slope %.2f" % slope)
    out = Path(args.json)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"results": results, "failures": failures}, indent=2) + "\n")
    for f in failures:
        print("FAIL " + f)
    print("POWDER_RIPPLE_REFERENCE failures=%d" % len(failures))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
