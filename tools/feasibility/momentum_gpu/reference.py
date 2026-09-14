"""Finite-step wrapper around the unchanged zero-time binary64 PIC/APIC reference."""
import math
from tools.feasibility.momentum_reference import Particle, add, scale, round_trip, stencil


def step(particles, dx, shape, dt, method):
    if not math.isfinite(dt) or dt <= 0:
        raise ValueError("Positive finite timestep required")
    # Validate old support before any numerical operation.
    for p in particles:
        stencil(p.position, dx, shape)
    transferred, grid = round_trip(particles, dx, shape, method)
    candidates = [Particle(add(p.position, scale(p.velocity, dt)), p.velocity, p.mass, p.affine)
                  for p in transferred]
    try:
        for p in candidates:
            stencil(p.position, dx, shape)
    except ValueError:
        return list(particles), grid, False
    return candidates, grid, True
