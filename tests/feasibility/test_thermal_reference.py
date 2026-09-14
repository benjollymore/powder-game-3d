"""Deterministic reference experiments. Run with standard-library unittest."""
import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.feasibility.thermal_reference import Grid, Material, Parcel, transfer_liquid


SOLID_A = Material("synthetic A", 1000, 10, 1000, 1000, 1000)
SOLID_B = Material("synthetic B", 2000, 20, 2000, 2000, 1000)
PCM = Material("synthetic phase-change material", 1000, 10, 1000, 2000, 300, 100000)


def full(material, temperature, dx=0.01, fraction=0):
    return Parcel.at_temperature(material, material.density * dx**3, temperature, fraction)


class ThermalReferenceTests(unittest.TestCase):
    def test_three_dimensional_hotspot_exchanges_with_six_faces(self):
        cells = [full(SOLID_A, 400 if i == 13 else 300) for i in range(27)]
        grid = Grid((3, 3, 3), 0.01, cells)
        initial = grid.energy()
        grid.step(0.5 * grid.stable_dt())
        face_neighbours = {4, 10, 12, 14, 16, 22}
        for i, cell in enumerate(cells):
            expected = 350 if i == 13 else (300 + 50 / 6 if i in face_neighbours else 300)
            self.assertAlmostEqual(cell.state()[0], expected, places=10)
        self.assertAlmostEqual(grid.energy(), initial, places=10)

    def test_insulated_two_material_blocks_10_seconds(self):
        cells = [full(SOLID_A if x < 4 else SOLID_B, 400 if x < 4 else 300)
                 for _z in range(4) for _y in range(4) for x in range(8)]
        grid = Grid((8, 4, 4), 0.01, cells)
        initial = grid.energy()
        steps = math.ceil(10 / (0.9 * grid.stable_dt()))
        dt = 10 / steps
        minimum, maximum = 400.0, 300.0
        for _ in range(steps):
            grid.step(dt)
            temperatures = [c.state()[0] for c in cells]
            minimum, maximum = min(minimum, min(temperatures)), max(maximum, max(temperatures))
            self.assertGreaterEqual(min(temperatures), 300 - 1e-10)
            self.assertLessEqual(max(temperatures), 400 + 1e-10)
        drift = abs(grid.energy() - initial) / abs(initial)
        self.assertLess(drift, 1e-12)
        self.assertEqual(grid.external_energy, 0)
        print(f"METRIC insulated_128_cells steps={steps} dt_s={dt:.9g} energy_drift={drift:.3g} temperature_range_K=[{minimum:.9g},{maximum:.9g}]")

    def test_two_material_equilibrium_uses_heat_capacity(self):
        cells = [full(SOLID_A, 400), full(SOLID_B, 300)]
        grid = Grid((2, 1, 1), 0.01, cells)
        capacities = [c.mass * c.material.cp_solid for c in cells]
        equilibrium = (capacities[0] * 400 + capacities[1] * 300) / sum(capacities)
        grid.advance(500, 0.5 * grid.stable_dt())
        for cell in cells:
            self.assertAlmostEqual(cell.state()[0], equilibrium, places=10)
        self.assertAlmostEqual(equilibrium, 320, places=10)

    def test_analytic_insulated_cosine_diffusion_converges(self):
        material = Material("synthetic diffusion", 1000, 100, 1000, 1000, 1000)
        alpha = material.conductivity / (material.density * material.cp_solid)
        length, duration, baseline, amplitude = 0.1, 1.0, 350, 20
        errors = []
        for n in (16, 32, 64):
            dx = length / n
            average_factor = math.sin(math.pi / (2 * n)) / (math.pi / (2 * n))
            initial = [baseline + amplitude * average_factor * math.cos(math.pi * (i + 0.5) / n) for i in range(n)]
            grid = Grid((n, 1, 1), dx, [full(material, t, dx) for t in initial])
            steps = math.ceil(duration / (0.5 * grid.stable_dt()))
            grid.advance(steps, duration / steps)
            decay = math.exp(-alpha * (math.pi / length)**2 * duration)
            exact = [baseline + (t - baseline) * decay for t in initial]
            rms = math.sqrt(math.fsum((c.state()[0] - t)**2 for c, t in zip(grid.cells, exact)) / n)
            errors.append(rms)
        self.assertLess(errors[1], errors[0] / 3)
        self.assertLess(errors[2], errors[1] / 3)
        self.assertLess(errors[2], 0.001)
        print(f"METRIC diffusion_rms_K_16_32_64={errors} refinement_ratios={[errors[i] / errors[i+1] for i in (0, 1)]}")

    def test_unsafe_timestep_is_rejected_and_would_overshoot(self):
        grid = Grid((2, 1, 1), 0.01, [full(SOLID_A, 300), full(SOLID_A, 400)])
        dt = 2 * grid.stable_dt()
        before = grid.snapshot()
        with self.assertRaisesRegex(ValueError, "diffusion bound"):
            grid.step(dt)
        self.assertEqual(grid.snapshot(), before)
        # Negative control: forward Euler without the bound takes cold 300 K to 500 K.
        capacity = grid.cells[0].mass * SOLID_A.cp_solid
        unsafe_cold = 300 + dt * grid.faces[0][2] * 100 / capacity
        self.assertAlmostEqual(unsafe_cold, 500)

    def test_latent_heat_plateau_and_source_ledger(self):
        cell = full(PCM, 290)
        grid = Grid((1, 1, 1), 0.01, [cell])
        initial = grid.energy()
        grid.add_energy(0, cell.mass * PCM.cp_solid * 10)
        self.assertAlmostEqual(cell.state()[0], 300)
        self.assertAlmostEqual(cell.state()[1], 0)
        for i in range(1, 11):
            grid.add_energy(0, cell.mass * PCM.latent_heat / 10)
            self.assertAlmostEqual(cell.state()[0], 300)
            self.assertAlmostEqual(cell.state()[1], i / 10)
        grid.add_energy(0, cell.mass * PCM.cp_liquid * 10)
        self.assertAlmostEqual(cell.state()[0], 310)
        self.assertAlmostEqual(grid.energy() - initial, grid.external_energy)
        self.assertAlmostEqual(grid.external_energy, 130)
        grid.add_energy(0, -grid.external_energy)
        self.assertAlmostEqual(cell.state()[0], 290)
        self.assertAlmostEqual(grid.external_energy, 0)

    def test_conduction_across_phase_change_conserves_energy(self):
        grid = Grid((2, 1, 1), 0.01, [full(PCM, 290), full(PCM, 360)])
        initial = grid.energy()
        phase_samples = 0
        for _ in range(300):
            grid.step(0.5 * grid.stable_dt())
            for cell in grid.cells:
                temperature, fraction = cell.state()
                self.assertGreaterEqual(temperature, 290 - 1e-10)
                self.assertLessEqual(temperature, 360 + 1e-10)
                if 0 < fraction < 1:
                    self.assertEqual(temperature, 300)
                    phase_samples += 1
        self.assertGreater(phase_samples, 0)
        self.assertLess(abs(grid.energy() - initial) / initial, 1e-12)
        print(f"METRIC conducting_phase_change plateau_samples={phase_samples} energy_drift={abs(grid.energy()-initial)/initial:.3g}")

    def test_liquid_mass_transfer_carries_specific_enthalpy(self):
        donor, receiver = Parcel.at_temperature(PCM, 2, 330), Parcel.at_temperature(PCM, 0.5, 310)
        initial_energy, initial_mass = donor.energy + receiver.energy, donor.mass + receiver.mass
        old_h = donor.energy / donor.mass
        transported = transfer_liquid(donor, receiver, 0.25)
        self.assertAlmostEqual(transported, 0.25 * old_h)
        self.assertEqual(donor.mass + receiver.mass, initial_mass)
        self.assertAlmostEqual(donor.energy + receiver.energy, initial_energy)
        self.assertAlmostEqual(donor.state()[0], 330)
        self.assertAlmostEqual(receiver.state()[0], (0.5 * 310 + 0.25 * 330) / 0.75)
        # A mass-only move could conserve total energy yet gives wrong specific enthalpies.
        wrong_donor_temperature = PCM.state(2 * old_h / 1.75)[0]
        self.assertGreater(abs(wrong_donor_temperature - 330), 1)
        transfer_liquid(donor, receiver, donor.mass)
        self.assertEqual((donor.mass, donor.energy), (0, 0))
        self.assertAlmostEqual(receiver.energy, initial_energy)
        self.assertAlmostEqual(receiver.state()[0], 326)

    def test_transfer_into_empty_and_reject_unsupported_without_mutation(self):
        donor, empty = Parcel.at_temperature(PCM, 1, 330), Parcel(PCM, 0, 0)
        transfer_liquid(donor, empty, 0.1)
        self.assertAlmostEqual(empty.state()[0], 330)
        for amount in (-0.1, 2, math.nan):
            before = donor.mass, donor.energy, empty.mass, empty.energy
            with self.assertRaises(ValueError):
                transfer_liquid(donor, empty, amount)
            self.assertEqual((donor.mass, donor.energy, empty.mass, empty.energy), before)
        with self.assertRaisesRegex(ValueError, "Mixed-material"):
            transfer_liquid(donor, Parcel.at_temperature(SOLID_B, 1, 310), 0.1)
        with self.assertRaisesRegex(ValueError, "fully liquid"):
            transfer_liquid(Parcel.at_temperature(PCM, 1, 300, 0.5), empty, 0.1)

    def test_partial_fill_conduction_is_explicitly_unsupported(self):
        cells = [full(PCM, 330), full(PCM, 330)]
        grid = Grid((2, 1, 1), 0.01, cells)
        transfer_liquid(cells[0], cells[1], cells[0].mass / 2)
        before = grid.snapshot()
        with self.assertRaisesRegex(ValueError, "full stationary"):
            grid.step(0.01)
        self.assertEqual(grid.snapshot(), before)

    def test_identical_ticks_are_batch_invariant(self):
        def make():
            return Grid((4, 2, 2), 0.01, [full(PCM, 290 + (i % 4) * 20) for i in range(16)])
        one, grouped = make(), make()
        dt = 0.8 * one.stable_dt()
        for _ in range(80):
            one.advance(1, dt)
        for count in (3, 7, 1, 20, 49):
            grouped.advance(count, dt)
        self.assertEqual(one.snapshot(), grouped.snapshot())

    def test_zero_conductivity_insulates_and_material_changes_need_new_faces(self):
        insulator = Material("synthetic insulator", 1000, 0, 1000, 1000, 1000)
        grid = Grid((2, 1, 1), 0.01, [full(SOLID_A, 400), full(insulator, 300)])
        before = tuple(c.energy for c in grid.cells)
        grid.advance(10, 100)
        self.assertEqual(tuple(c.energy for c in grid.cells), before)
        grid.cells[1].material = SOLID_A
        with self.assertRaisesRegex(ValueError, "rebuilding conduction faces"):
            grid.step(1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
