#!/usr/bin/env python3
"""Exact local-field diagnostic for fields.glsl, not a replacement fluid solver.
Coordinates and lengths are in cell units. Only the frozen isolated-cell and
infinite horizontal-sheet reconstructions are modeled; no time advances.
"""
import json
import math
from pathlib import Path


def density(amount):
    fill = min(max(amount / 200.0, 0.0), 1.0)
    raw = fill / (fill + 0.5) if fill < 0.5 else 0.5 / (1.5 - fill)
    return math.floor(raw * 255.0 + 0.5) / 255.0


def isolated_field(point, amount):
    result = density(amount)
    for coordinate in point:
        result *= max(1.0 - abs(coordinate - 0.5), 0.0)
    return result


def main():
    rows = []
    for amount in (1, 50, 100, 150, 200, 255):
        peak = density(amount)
        rows.append({"amount": amount, "fill": amount / 200.0,
                     "density_byte": round(peak * 255),
                     "isolated_peak": peak,
                     "unsupported_sheet_iso_thickness_cells": max(2 - 1 / peak, 0)})
    # Every ray in this noncentral window has an interior field peak >0.5.
    # Yet both voxel-face samples are <0.5, as are all further samples.
    misses = 0
    for ix in range(20):
        for iy in range(20):
            x = 0.25 + (ix + 0.5) / 40.0
            y = 0.25 + (iy + 0.5) / 40.0
            peak = isolated_field((x, y, 0.5), 200)
            faces = [isolated_field((x, y, z), 200) for z in (0.0, 1.0)]
            assert peak > 0.5 and max(faces) < 0.5
            misses += 1
    assert density(50) < 0.5  # There is no surface for any traversal to find.
    result = {"units": "cell lengths; amount200 is one full cell",
              "full_cell_rays_with_real_surface_but_no_boundary_crossing": misses,
              "rows": rows}
    print(json.dumps(result, indent=2))
    destination = Path("docs/milestone/ordinary-liquid-evidence")
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "field-reference.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
