#!/usr/bin/env python3
"""Source-grounded allocation arithmetic, not a GPU memory/timing measurement.

Run from any directory; --source-root can point to the integration checkout.
Texture byte layouts are inventoried in docs/milestone/architecture-feasibility.md.
No engine startup, dependencies, or filesystem mutations.
"""
import argparse
import json
from pathlib import Path
import re


def constant(source, name):
    match = re.search(r"const " + name + r"\s*:=\s*(\d+)", source)
    if not match:
        raise ValueError(f"Missing integer source constant: {name}")
    return int(match.group(1))


def budget(root, n):
    if n < 32 or n % 32:
        raise ValueError("This inventory models grid sizes divisible by 32, >=32")
    sim = (root / "scripts/sim/voxel_sim.gd").read_text()
    scene = (root / "scenes/sim_volume.tscn").read_text()
    caps = [int(v) for v in re.findall(r"^capacity = (\d+)$", scene, re.M)]
    if len(caps) != 4:
        raise ValueError("Expected grain, leaf, droplet, FX capacities in scene order")
    cells = n ** 3
    air = (n // constant(sim, "AIR_SUB")) ** 3
    mips = constant(sim, "FIELDS_MIPS")
    allocations = {
        "voxel_rgba8": 4 * cells,
        "fields_rgba8_with_mips": 4 * sum((n >> m) ** 3 for m in range(mips)),
        "occupancy_rgba8": 4 * (n // constant(sim, "BRICK")) ** 3,
        "sunvis_r8": (n // constant(sim, "SUNVIS_DIV")) ** 3,
        "air_velocity_ping_pong_rgba16f": 16 * air,
        "air_pressure_ping_pong_r16f": 4 * air,
        "air_divergence_r16f": 2 * air,
        "air_occupancy_r8": air,
        "air_source_rgba16f": 8 * air,
        "render_instances_64_bytes": 64 * sum(caps),
        "cosmetic_fx_pool_48_bytes": 48 * caps[3],
        "fx_spawn_requests_32_bytes": 32 * constant(sim, "FX_SPAWN_CAPACITY"),
        "activity_counters": constant(sim, "COUNTER_BYTES"),
        # Current table: 10 elements * 32 bytes, 5 reactions * 16 bytes.
        "material_and_reaction_tables": 10 * 32 + 5 * 16,
    }
    jacobi = int(re.search(r"@export var jacobi_iterations := (\d+)", sim)[1])
    air_passes = 4 + jacobi + (jacobi & 1)
    sun_passes = (n // constant(sim, "SUNVIS_DIV") +
                  constant(sim, "SUNVIS_SLABS_PER_DISPATCH") - 1) // constant(sim, "SUNVIS_SLABS_PER_DISPATCH")
    return {
        "grid": n, "cells": cells, "world_metres_per_side": n * 0.01,
        "allocations_bytes": allocations,
        "total_accounted_bytes": sum(allocations.values()),
        "total_accounted_mib": round(sum(allocations.values()) / 2**20, 6),
        "default_physics_dispatches_per_tick": air_passes + 1 + 2,
        "derived_dispatches_per_rebuild_excluding_fx": 3 + (mips - 1) + sun_passes,
        "physical_sprite_buffer_clear_bytes_per_rebuild": 64 * sum(caps[:3]),
        "one_cpu_voxel_snapshot_bytes_excluded_from_total": 4 * cells,
        "hypothetical_extra_enthalpy_fp32_ping_pong_bytes": 8 * cells,
        # Illustrative tightly packed position3,velocity3,mass,volume,C9,F9,plastic1,id1.
        "hypothetical_mpm_112_bytes_times_4_particles_per_occupied_cell_at_10_percent":
            112 * 4 * ((cells + 9) // 10),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--grid", type=int, nargs="+", default=[128, 256, 512])
    args = parser.parse_args()
    print(json.dumps([budget(args.source_root, n) for n in args.grid], indent=2))


if __name__ == "__main__":
    main()
