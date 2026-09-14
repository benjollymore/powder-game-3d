"""Isolated binary64 thermal accounting reference; no production dependencies.

SI units: metres, seconds, kilograms, kelvin, joules. Coefficients used by the
tests are synthetic. Stationary conduction requires full, equal cubic cells.
Parcel transport demonstrates accounting only, not a liquid flow solver.
"""
from dataclasses import dataclass
import math

REFERENCE_K = 273.15


@dataclass(frozen=True)
class Material:
    name: str
    density: float                 # kg/m^3, equal in both phases
    conductivity: float            # W/(m K), equal in both phases
    cp_solid: float                # J/(kg K)
    cp_liquid: float               # J/(kg K)
    melting_kelvin: float          # K
    latent_heat: float = 0.0       # J/kg

    def __post_init__(self):
        values = (self.density, self.conductivity, self.cp_solid,
                  self.cp_liquid, self.melting_kelvin, self.latent_heat)
        if not all(math.isfinite(v) for v in values):
            raise ValueError("Material coefficients must be finite")
        if min(self.density, self.cp_solid, self.cp_liquid, self.melting_kelvin) <= 0:
            raise ValueError("Density, capacities and melting temperature must be positive")
        if min(self.conductivity, self.latent_heat) < 0:
            raise ValueError("Conductivity and latent heat cannot be negative")

    @property
    def solid_at_melt(self):
        return self.cp_solid * (self.melting_kelvin - REFERENCE_K)

    def specific_enthalpy(self, kelvin, liquid_fraction=0.0):
        if not math.isfinite(kelvin) or kelvin < 0:
            raise ValueError("Temperature must be finite and nonnegative kelvin")
        if not math.isfinite(liquid_fraction) or not 0 <= liquid_fraction <= 1:
            raise ValueError("Liquid fraction must be in [0, 1]")
        if kelvin < self.melting_kelvin:
            return self.cp_solid * (kelvin - REFERENCE_K)
        if kelvin == self.melting_kelvin:
            return self.solid_at_melt + liquid_fraction * self.latent_heat
        return (self.solid_at_melt + self.latent_heat +
                self.cp_liquid * (kelvin - self.melting_kelvin))

    def state(self, specific_enthalpy):
        if not math.isfinite(specific_enthalpy):
            raise ValueError("Specific enthalpy must be finite")
        h = specific_enthalpy - self.solid_at_melt
        if h < 0:
            temperature, fraction = self.melting_kelvin + h / self.cp_solid, 0.0
        elif self.latent_heat > 0 and h <= self.latent_heat:
            temperature, fraction = self.melting_kelvin, h / self.latent_heat
        else:
            temperature, fraction = self.melting_kelvin + (h - self.latent_heat) / self.cp_liquid, 1.0
        if temperature < -1e-10:
            raise ValueError("Enthalpy implies negative absolute temperature")
        return max(temperature, 0.0), fraction


@dataclass
class Parcel:
    material: Material
    mass: float                    # kg
    energy: float                  # J, enthalpy relative to REFERENCE_K

    def __post_init__(self):
        self.validate()

    def validate(self):
        if not math.isfinite(self.mass) or self.mass < 0 or not math.isfinite(self.energy):
            raise ValueError("Invalid parcel mass or energy")
        if self.mass == 0:
            if self.energy != 0:
                raise ValueError("Empty parcels cannot retain energy")
        else:
            self.material.state(self.energy / self.mass)

    @classmethod
    def at_temperature(cls, material, mass, kelvin, liquid_fraction=0.0):
        return cls(material, mass, mass * material.specific_enthalpy(kelvin, liquid_fraction))

    def state(self):
        if self.mass == 0:
            raise ValueError("An empty parcel has no temperature")
        return self.material.state(self.energy / self.mass)


def transfer_liquid(donor, receiver, accepted_mass):
    """Atomic homogeneous-liquid transfer; caller already resolved space/flow.

    Returns transported joules. Mixed materials and partially melted donors
    need phase/species-selective transport and are deliberately unsupported.
    """
    donor.validate()
    receiver.validate()
    if donor is receiver:
        raise ValueError("Donor and receiver must differ")
    if donor.material != receiver.material:
        raise ValueError("Mixed-material enthalpy transport is not implemented")
    if not math.isfinite(accepted_mass) or not 0 <= accepted_mass <= donor.mass:
        raise ValueError("Accepted mass exceeds available material")
    if accepted_mass == 0:
        return 0.0
    if donor.state()[1] < 1.0:
        raise ValueError("Only homogeneous fully liquid donors are supported")
    joules = donor.energy * (accepted_mass / donor.mass)
    remaining = donor.mass - accepted_mass
    next_donor = Parcel(donor.material, remaining, donor.energy - joules if remaining else 0.0)
    next_receiver = Parcel(receiver.material, receiver.mass + accepted_mass, receiver.energy + joules)
    donor.mass, donor.energy = next_donor.mass, next_donor.energy
    receiver.mass, receiver.energy = next_receiver.mass, next_receiver.energy
    return joules


class Grid:
    """Insulated stationary finite-volume grid with explicit face exchange.

    Every face is visited once using old temperatures; both cell energy deltas
    receive the same opposite transfer. A grid does not own advective motion.
    """
    def __init__(self, shape, cell_metres, cells):
        if len(shape) != 3 or any(type(n) is not int or n < 1 for n in shape):
            raise ValueError("Shape must contain three positive integer dimensions")
        if not math.isfinite(cell_metres) or cell_metres <= 0:
            raise ValueError("Cell size must be positive and finite")
        if math.prod(shape) != len(cells) or len({id(c) for c in cells}) != len(cells):
            raise ValueError("Each grid slot needs its own parcel")
        self.shape, self.dx, self.cells = tuple(shape), cell_metres, list(cells)
        self.materials = tuple(c.material for c in cells)
        self.external_energy = 0.0
        self.ticks = 0
        self.faces = []
        nx, ny, nz = self.shape
        for z in range(nz):
            for y in range(ny):
                for x in range(nx):
                    i = x + nx * (y + ny * z)
                    for condition, stride in ((x + 1 < nx, 1), (y + 1 < ny, nx), (z + 1 < nz, nx * ny)):
                        if condition:
                            j = i + stride
                            ki, kj = self.cells[i].material.conductivity, self.cells[j].material.conductivity
                            conductance = 0.0 if ki + kj == 0 else 2 * ki * kj / (ki + kj) * self.dx
                            self.faces.append((i, j, conductance))
        self._validate_full_cells()

    def _validate_full_cells(self):
        for cell, material in zip(self.cells, self.materials):
            cell.validate()
            if cell.material != material:
                raise ValueError("Material changes require rebuilding conduction faces")
            expected = cell.material.density * self.dx ** 3
            if not math.isclose(cell.mass, expected, rel_tol=1e-12, abs_tol=0):
                raise ValueError("Conduction geometry supports only full stationary cubic cells")

    def stable_dt(self):
        self._validate_full_cells()
        conductance = [0.0] * len(self.cells)
        for i, j, value in self.faces:
            conductance[i] += value
            conductance[j] += value
        return min((cell.mass * min(cell.material.cp_solid, cell.material.cp_liquid) / total
                    for cell, total in zip(self.cells, conductance) if total > 0), default=math.inf)

    def step(self, dt):
        if not math.isfinite(dt) or dt <= 0:
            raise ValueError("Time step must be finite and positive")
        if dt > self.stable_dt() * (1 + 1e-12):
            raise ValueError("Time step exceeds conservative explicit diffusion bound")
        temperatures = [c.state()[0] for c in self.cells]
        delta = [0.0] * len(self.cells)
        for i, j, conductance in self.faces:
            joules = dt * conductance * (temperatures[j] - temperatures[i])
            delta[i] += joules
            delta[j] -= joules
        for cell, joules in zip(self.cells, delta):
            cell.energy += joules
        self.ticks += 1

    def advance(self, count, dt):
        if type(count) is not int or count < 0:
            raise ValueError("Tick count must be a nonnegative integer")
        for _ in range(count):
            self.step(dt)

    def add_energy(self, index, joules):
        cell = self.cells[index]
        proposed = Parcel(cell.material, cell.mass, cell.energy + joules)
        cell.energy = proposed.energy
        self.external_energy += joules

    def energy(self):
        return math.fsum(c.energy for c in self.cells)

    def snapshot(self):
        return tuple((c.mass, c.energy) for c in self.cells), self.ticks, self.external_energy
