"""Binary64 PIC/APIC transfer reference at fixed positions (dt=0).

Quadratic tensor-product B-splines, complete interior 3x3x3 support.
No motion integration, forces, pressure, deformation, collisions or GPU work.
SI units: position/dx metres, mass kg, velocity m/s, affine C in 1/s.
"""
from dataclasses import dataclass
import itertools
import math

ZERO = (0.0, 0.0, 0.0)
ZERO_MATRIX = (ZERO, ZERO, ZERO)


def add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def scale(a, s):
    return tuple(s * x for x in a)


def dot(a, b):
    return math.fsum(x * y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def matvec(matrix, vector):
    return tuple(dot(row, vector) for row in matrix)


def vector_sum(vectors):
    vectors = list(vectors)
    return tuple(math.fsum(v[k] for v in vectors) for k in range(3))


@dataclass(frozen=True)
class Particle:
    position: tuple
    velocity: tuple
    mass: float
    affine: tuple = ZERO_MATRIX

    def __post_init__(self):
        if len(self.position) != 3 or len(self.velocity) != 3 or len(self.affine) != 3 or any(len(r) != 3 for r in self.affine):
            raise ValueError("Expected 3D position, velocity and 3x3 affine matrix")
        values = (*self.position, *self.velocity, self.mass, *(v for r in self.affine for v in r))
        if not all(math.isfinite(v) for v in values) or self.mass <= 0:
            raise ValueError("Finite particle state and positive mass required")


@dataclass(frozen=True)
class Node:
    mass: float
    velocity: tuple


def stencil(position, dx, shape):
    if not math.isfinite(dx) or dx <= 0 or len(shape) != 3 or any(type(n) is not int or n < 3 for n in shape):
        raise ValueError("Positive spacing and three grid dimensions >=3 required")
    if len(position) != 3 or not all(math.isfinite(x) for x in position):
        raise ValueError("Finite 3D position required")
    base = tuple(math.floor(x / dx - 0.5) for x in position)
    if any(b < 0 or b + 2 >= n for b, n in zip(base, shape)):
        raise ValueError("Particle requires complete interior support; boundaries unimplemented")
    weights = []
    for x, b in zip(position, base):
        f = x / dx - b
        weights.append((0.5 * (1.5 - f)**2, 0.75 - (f - 1)**2, 0.5 * (f - 0.5)**2))
    out = []
    for local in itertools.product(range(3), repeat=3):
        node = tuple(b + i for b, i in zip(base, local))
        weight = math.prod(weights[a][local[a]] for a in range(3))
        if weight > 0:
            out.append((node, weight, sub(scale(node, dx), position)))
    return out


def _method(method):
    if method not in ("pic", "apic"):
        raise ValueError("Method must be pic or apic")


def particle_to_grid(particles, dx, shape, method="apic"):
    _method(method)
    accum = {}
    for p in particles:
        if method == "pic" and p.affine != ZERO_MATRIX:
            raise ValueError("PIC input must explicitly omit affine state")
        for index, weight, offset in stencil(p.position, dx, shape):
            mass = weight * p.mass
            velocity = add(p.velocity, matvec(p.affine, offset)) if method == "apic" else p.velocity
            if index not in accum:
                accum[index] = [0.0, [0.0, 0.0, 0.0]]
            accum[index][0] += mass
            for axis in range(3):
                accum[index][1][axis] += mass * velocity[axis]
    return {index: Node(mass, scale(momentum, 1 / mass)) for index, (mass, momentum) in accum.items()}


def grid_to_particle(particles, grid, dx, shape, method="apic"):
    _method(method)
    result = []
    for p in particles:
        velocity = [0.0] * 3
        affine = [[0.0] * 3 for _ in range(3)]
        for index, weight, offset in stencil(p.position, dx, shape):
            if index not in grid or grid[index].mass <= 0:
                raise ValueError("Positive-mass nodes required throughout particle support")
            node_velocity = grid[index].velocity
            for a in range(3):
                velocity[a] += weight * node_velocity[a]
                if method == "apic":
                    for b in range(3):
                        affine[a][b] += (4 / dx**2) * weight * node_velocity[a] * offset[b]
        result.append(Particle(p.position, tuple(velocity), p.mass, tuple(tuple(row) for row in affine)))
    return result


def round_trip(particles, dx, shape, method="apic"):
    grid = particle_to_grid(particles, dx, shape, method)
    return grid_to_particle(particles, grid, dx, shape, method), grid


def particle_totals(particles, dx, origin=ZERO):
    """Include the affine rotational moment and its weighted kinetic energy.

    Quadratic B-spline D = dx^2/4 I. Energy is 1/2 sum_p,i m_p w_ip
    |v_p + C_p(x_i-x_p)|^2, not only centre-velocity particle energy.
    """
    d = dx**2 / 4
    orbital, internal = [], []
    for p in particles:
        orbital.append(scale(cross(sub(p.position, origin), p.velocity), p.mass))
        c = p.affine
        internal.append(scale((c[2][1] - c[1][2], c[0][2] - c[2][0], c[1][0] - c[0][1]), p.mass * d))
    center_energy = 0.5 * math.fsum(p.mass * dot(p.velocity, p.velocity) for p in particles)
    affine_energy = 0.5 * d * math.fsum(p.mass * math.fsum(v*v for row in p.affine for v in row) for p in particles)
    return {
        "mass": math.fsum(p.mass for p in particles),
        "linear_momentum": vector_sum(scale(p.velocity, p.mass) for p in particles),
        "orbital_angular_momentum": vector_sum(orbital),
        "affine_angular_momentum": vector_sum(internal),
        "angular_momentum": add(vector_sum(orbital), vector_sum(internal)),
        "center_kinetic_energy": center_energy,
        "affine_kinetic_energy": affine_energy,
        "kinetic_energy": center_energy + affine_energy,
    }


def grid_totals(grid, dx, origin=ZERO):
    return {
        "mass": math.fsum(n.mass for n in grid.values()),
        "linear_momentum": vector_sum(scale(n.velocity, n.mass) for n in grid.values()),
        "angular_momentum": vector_sum(scale(cross(sub(scale(index, dx), origin), n.velocity), n.mass)
                                       for index, n in grid.items()),
        "kinetic_energy": 0.5 * math.fsum(n.mass * dot(n.velocity, n.velocity) for n in grid.values()),
    }
