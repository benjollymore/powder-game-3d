"""Force-free, fixed-position 3D transfer experiments; not fluid tests."""
import itertools
import json
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.feasibility.momentum_reference import (
    ZERO, ZERO_MATRIX, Node, Particle, add, dot, grid_to_particle, grid_totals,
    matvec, particle_to_grid, particle_totals, round_trip, scale, stencil, sub,
)

DX, SHAPE = 0.1, (8, 8, 8)
ROTATION = ((0.0, -3.0, 2.0), (3.0, 0.0, -1.0), (-2.0, 1.0, 0.0))
AFFINE = ((-0.2, -2.0, 0.3), (2.0, 0.1, -1.0), (-0.4, 0.5, 0.3))


def norm(v):
    return math.sqrt(dot(v, v))


def fixture(matrix=AFFINE, translation=(0.3, -0.2, 0.1), affine=True):
    positions = list(itertools.product((0.23, 0.315, 0.41), repeat=3))
    masses = [0.01 * (1 + (i % 5) / 5) for i in range(len(positions))]
    total = math.fsum(masses)
    center = tuple(math.fsum(m*x[a] for m, x in zip(masses, positions)) / total for a in range(3))
    particles = [Particle(x, add(translation, matvec(matrix, sub(x, center))), m, matrix if affine else ZERO_MATRIX)
                 for x, m in zip(positions, masses)]
    return particles, center


class MomentumReferenceTests(unittest.TestCase):
    def assert_vector_close(self, a, b, tolerance=1e-12):
        self.assertLessEqual(norm(sub(a, b)), tolerance)

    def assert_conserved(self, before, after):
        self.assertAlmostEqual(before['mass'], after['mass'], places=13)
        self.assert_vector_close(before['linear_momentum'], after['linear_momentum'])
        self.assert_vector_close(before['angular_momentum'], after['angular_momentum'])

    def test_quadratic_weights_reproduce_partition_position_covariance(self):
        for position in ((0.23, 0.315, 0.41), (0.3, 0.25, 0.35), (0.275, 0.422, 0.166)):
            support = stencil(position, DX, SHAPE)
            self.assertAlmostEqual(math.fsum(w for _, w, _ in support), 1, places=14)
            for a in range(3):
                self.assertAlmostEqual(math.fsum(w*r[a] for _, w, r in support), 0, places=14)
                for b in range(3):
                    covariance = math.fsum(w*r[a]*r[b] for _, w, r in support)
                    self.assertAlmostEqual(covariance, DX**2 / 4 if a == b else 0, places=14)

    def test_pic_and_apic_preserve_constant_translation(self):
        particles, origin = fixture(ZERO_MATRIX)
        for method in ('pic', 'apic'):
            current = particles
            before = particle_totals(current, DX, origin)
            for _ in range(20):
                current, grid = round_trip(current, DX, SHAPE, method)
                self.assert_conserved(before, grid_totals(grid, DX, origin))
            self.assert_conserved(before, particle_totals(current, DX, origin))
            for old, new in zip(particles, current):
                self.assert_vector_close(old.velocity, new.velocity)

    def test_apic_reproduces_full_affine_field(self):
        original, origin = fixture()
        current = original
        initial = particle_totals(original, DX, origin)
        for _ in range(20):
            current, grid = round_trip(current, DX, SHAPE)
            for index, node in grid.items():
                expected = add((0.3, -0.2, 0.1), matvec(AFFINE, sub(scale(index, DX), origin)))
                self.assert_vector_close(node.velocity, expected)
            self.assert_conserved(initial, grid_totals(grid, DX, origin))
            self.assert_conserved(initial, particle_totals(current, DX, origin))
        velocity_error = max(norm(sub(a.velocity, b.velocity)) for a, b in zip(original, current))
        matrix_error = max(abs(a.affine[i][j] - b.affine[i][j]) for a, b in zip(original, current) for i in range(3) for j in range(3))
        self.assertLess(velocity_error, 1e-12)
        self.assertLess(matrix_error, 1e-12)
        self.assertAlmostEqual(initial['kinetic_energy'], particle_totals(current, DX, origin)['kinetic_energy'], places=12)
        print(f'METRIC affine_20_roundtrips max_velocity_error_m_s={velocity_error:.3g} max_C_error_per_s={matrix_error:.3g}')

    def test_pic_rotation_dissipation_negative_control(self):
        results = {}
        for method in ('pic', 'apic'):
            current, origin = fixture(ROTATION, ZERO, method == 'apic')
            initial = particle_totals(current, DX, origin)
            previous_energy = initial['kinetic_energy']
            previous_totals = initial
            for _ in range(20):
                current, grid = round_trip(current, DX, SHAPE, method)
                self.assert_conserved(previous_totals, grid_totals(grid, DX, origin))
                totals = particle_totals(current, DX, origin)
                self.assertAlmostEqual(totals['mass'], initial['mass'], places=13)
                self.assert_vector_close(totals['linear_momentum'], initial['linear_momentum'])
                self.assertLessEqual(totals['kinetic_energy'], previous_energy + 1e-12)
                previous_energy = totals['kinetic_energy']
                previous_totals = totals
            results[method] = {
                'angular_retained': norm(totals['angular_momentum']) / norm(initial['angular_momentum']),
                'center_energy_retained': totals['center_kinetic_energy'] / initial['center_kinetic_energy'],
                'total_energy_retained': totals['kinetic_energy'] / initial['kinetic_energy'],
                'initial_center_energy_J': initial['center_kinetic_energy'],
                'initial_affine_energy_J': initial['affine_kinetic_energy'],
            }
        self.assertLess(results['pic']['angular_retained'], 0.1)
        self.assertLess(results['pic']['center_energy_retained'], 0.1)
        self.assertAlmostEqual(results['apic']['angular_retained'], 1, places=11)
        self.assertAlmostEqual(results['apic']['center_energy_retained'], 1, places=11)
        print('METRIC rotation_20_roundtrips ' + json.dumps(results, sort_keys=True))

    def test_single_particle_spin_requires_affine_angular_momentum(self):
        particles = [Particle((0.275, 0.322, 0.416), ZERO, 0.02, ROTATION)]
        initial = particle_totals(particles, DX)
        self.assertEqual(initial['orbital_angular_momentum'], ZERO)
        self.assertGreater(norm(initial['affine_angular_momentum']), 0.0001)
        after, grid = round_trip(particles, DX, SHAPE)
        self.assert_conserved(initial, grid_totals(grid, DX))
        self.assert_conserved(initial, particle_totals(after, DX))
        self.assertAlmostEqual(initial['kinetic_energy'], grid_totals(grid, DX)['kinetic_energy'], places=14)
        # Dropping C erases this spin entirely; centre velocity alone cannot encode it.
        erased = [Particle(particles[0].position, ZERO, particles[0].mass)]
        self.assertEqual(particle_totals(erased, DX)['angular_momentum'], ZERO)

    def test_nonaffine_roundtrips_conserve_momentum_but_dissipate_energy(self):
        particles, origin = fixture()
        current = [Particle(p.position, (math.sin(i*1.7), math.cos(i*0.9), math.sin(i*0.6)+0.2), p.mass,
                            tuple(tuple(c * math.cos(i*0.3) for c in row) for row in AFFINE))
                   for i, p in enumerate(particles)]
        initial = particle_totals(current, DX, origin)
        previous = initial
        for _ in range(20):
            current, grid = round_trip(current, DX, SHAPE)
            grid_state, state = grid_totals(grid, DX, origin), particle_totals(current, DX, origin)
            self.assert_conserved(initial, grid_state)
            self.assert_conserved(initial, state)
            self.assertLessEqual(grid_state['kinetic_energy'], previous['kinetic_energy'] + 1e-12)
            self.assertLessEqual(state['kinetic_energy'], grid_state['kinetic_energy'] + 1e-12)
            previous = state
        self.assertLess(state['kinetic_energy'], initial['kinetic_energy'] * 0.9)
        print(f"METRIC nonaffine_apic_20_roundtrips energy_retained={state['kinetic_energy']/initial['kinetic_energy']:.9g} linear_error={norm(sub(initial['linear_momentum'],state['linear_momentum'])):.3g} angular_error={norm(sub(initial['angular_momentum'],state['angular_momentum'])):.3g}")

    def test_arbitrary_grid_velocity_transfers_momentum_to_apic(self):
        particles, origin = fixture()
        grid = particle_to_grid(particles, DX, SHAPE)
        grid = {index: Node(node.mass, (math.sin(index[0]), math.cos(index[1]), index[2]*0.1)) for index, node in grid.items()}
        # Prescribed fixture velocities, not an unmodelled pressure/force step.
        before = grid_totals(grid, DX, origin)
        after = particle_totals(grid_to_particle(particles, grid, DX, SHAPE), DX, origin)
        self.assert_conserved(before, after)
        self.assertLessEqual(after['kinetic_energy'], before['kinetic_energy'] + 1e-12)

    def test_zero_C_initialization_does_not_reproduce_affine_velocity(self):
        original, origin = fixture(ROTATION, ZERO, affine=False)
        after, _ = round_trip(original, DX, SHAPE, 'apic')
        self.assertGreater(max(norm(sub(p.velocity, q.velocity)) for p, q in zip(original, after)), 0.01)
        self.assert_conserved(particle_totals(original, DX, origin), particle_totals(after, DX, origin))

    def test_boundary_and_missing_nodes_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'boundaries unimplemented'):
            stencil((0.01, 0.3, 0.3), DX, SHAPE)
        particles, _ = fixture()
        grid = particle_to_grid(particles, DX, SHAPE)
        grid.pop(next(iter(grid)))
        with self.assertRaisesRegex(ValueError, 'Positive-mass nodes'):
            grid_to_particle(particles, grid, DX, SHAPE)
        with self.assertRaisesRegex(ValueError, 'explicitly omit affine'):
            particle_to_grid(particles, DX, SHAPE, 'pic')

    def test_grouping_roundtrips_does_not_change_state_or_positions(self):
        original, _ = fixture()
        individual, grouped = original, original
        for _ in range(20):
            individual, _ = round_trip(individual, DX, SHAPE)
        for count in (3, 5, 12):
            for _ in range(count):
                grouped, _ = round_trip(grouped, DX, SHAPE)
        self.assertEqual(individual, grouped)
        self.assertEqual([p.position for p in original], [p.position for p in individual])


if __name__ == '__main__':
    unittest.main(verbosity=2)
