"""Isolated binary64 mass/enthalpy contract for current integer liquid amounts.

No production imports, pressure-work model, phase-selective transport or chemistry.
The column target matches hydro.glsl integer arithmetic. Its target amounts do
not determine an advective path: two explicit remap policies expose that choice.
"""
from dataclasses import dataclass
import math
from tools.feasibility.thermal_reference import Material

FULL, MAX_AMOUNT, COMP = 200, 255, 2


def amounts_checked(amounts):
    amounts = tuple(amounts)
    if not amounts or any(type(a) is not int or not 0 <= a <= MAX_AMOUNT for a in amounts):
        raise ValueError("Amounts must be integer bytes in a nonempty run")
    return amounts


def column_target(amounts):
    """Port of hydro.glsl profile_column; one contiguous nonzero liquid run."""
    amounts = amounts_checked(amounts)
    if 0 in amounts:
        raise ValueError("Production hydro splits runs at air; zero is not inside a run")
    n, mass = len(amounts), sum(amounts)
    height = 0
    for h in range(1, n + 1):
        if h * FULL + COMP * h * (h - 1) // 2 > mass:
            break
        height = h
    remainder = mass - (height * FULL + COMP * height * (height - 1) // 2)
    extra, extra_rem = (0, 0)
    if height == n:
        extra, extra_rem = divmod(remainder, n)
        remainder = 0
    result, carry = [], 0
    for k in range(n):
        want = (FULL + COMP * (height - 1 - k) + extra + (k < extra_rem)
                if k < height else remainder if k == height else 0)
        want += carry
        carry = max(want - MAX_AMOUNT, 0)
        result.append(min(want, MAX_AMOUNT))
    assert carry == 0 and sum(result) == mass
    return tuple(result)


@dataclass(frozen=True)
class Run:
    material: Material
    mass_per_unit: float
    amounts: tuple
    energy: tuple

    def __post_init__(self):
        if amounts_checked(self.amounts) != self.amounts or len(self.energy) != len(self.amounts):
            raise ValueError("Immutable aligned amount/energy tuples required")
        if not math.isfinite(self.mass_per_unit) or self.mass_per_unit <= 0:
            raise ValueError("A material-specific mass per amount unit is required")
        for amount, energy in zip(self.amounts, self.energy):
            if not math.isfinite(energy) or (amount == 0 and energy != 0):
                raise ValueError("Energy must be finite and empty cells must have zero energy")
            if amount:
                _, fraction = self.material.state(energy / (amount * self.mass_per_unit))
                if fraction < 1:
                    raise ValueError("This remap supports homogeneous fully liquid material only")

    @classmethod
    def at_temperatures(cls, material, mass_per_unit, amounts, temperatures):
        amounts = amounts_checked(amounts)
        if len(amounts) != len(temperatures):
            raise ValueError("Temperature shape mismatch")
        return cls(material, mass_per_unit, amounts, tuple(
            a * mass_per_unit * material.specific_enthalpy(t) if a else 0.
            for a, t in zip(amounts, temperatures)))

    def temperatures(self):
        return tuple(self.material.state(e / (a * self.mass_per_unit))[0] if a else None
                     for a, e in zip(self.amounts, self.energy))

    def mass(self):
        return sum(self.amounts) * self.mass_per_unit

    def joules(self):
        return math.fsum(self.energy)


@dataclass(frozen=True)
class Transfer:
    donor: int
    receiver: int
    units: int
    joules: float


@dataclass(frozen=True)
class Ledger:
    old_units: int
    new_units: int
    old_energy: float
    new_energy: float
    mass_in: float = 0.
    mass_out: float = 0.
    energy_in: float = 0.
    energy_out: float = 0.

    def residuals(self, mass_per_unit):
        return ((self.new_units - self.old_units) * mass_per_unit - self.mass_in + self.mass_out,
                self.new_energy - self.old_energy - self.energy_in + self.energy_out)


def remap(run, target, policy="monotone"):
    """Consume one immutable old state and an already accepted amount target.

    monotone preserves parcel order along the line via mass-coordinate overlap.
    retain preserves min(old,new) locally, matching surplus donors to deficits
    in ascending index order. Both conserve totals but imply different paths.
    Returns new state, explicit accepted transfers (including retained mass), ledger.
    """
    target = amounts_checked(target)
    if len(target) != len(run.amounts) or sum(target) != sum(run.amounts):
        raise ValueError("Remap target must conserve integer mass and shape")
    if policy not in ("monotone", "retain"):
        raise ValueError("An explicit supported remap policy is required")
    old, need = list(run.amounts), list(target)
    segments = [[] for _ in old]
    if policy == "retain":
        for i in range(len(old)):
            keep = min(old[i], need[i])
            if keep:
                segments[i].append((i, keep))
            old[i] -= keep
            need[i] -= keep
    donor = receiver = 0
    while donor < len(old) and receiver < len(need):
        if old[donor] == 0:
            donor += 1
        elif need[receiver] == 0:
            receiver += 1
        else:
            units = min(old[donor], need[receiver])
            segments[donor].append((receiver, units))
            old[donor] -= units
            need[receiver] -= units
    assert not any(old) and not any(need)
    incoming = [[] for _ in target]
    transfers = []
    for i, parts in enumerate(segments):
        sent = []
        for part, (j, units) in enumerate(parts):
            # Final donor segment receives its energy remainder. No energy is
            # discarded when the original cell empties, including negative h.
            q = (run.energy[i] - math.fsum(sent) if part == len(parts) - 1
                 else run.energy[i] * (units / run.amounts[i]))
            sent.append(q)
            incoming[j].append(q)
            transfers.append(Transfer(i, j, units, q))
    result = Run(run.material, run.mass_per_unit, target, tuple(math.fsum(q) for q in incoming))
    ledger = Ledger(sum(run.amounts), sum(target), run.joules(), result.joules())
    return result, tuple(transfers), ledger


def replace_cell(run, index, amount, temperature):
    """External edit, not conservation inside a closed system. Same material only."""
    if type(index) is not int or not 0 <= index < len(run.amounts):
        raise ValueError("Invalid edit index")
    amounts_checked([amount])
    replacement = Run.at_temperatures(run.material, run.mass_per_unit, [amount], [temperature])
    amounts, energy = list(run.amounts), list(run.energy)
    amounts[index], energy[index] = amount, replacement.energy[0]
    result = Run(run.material, run.mass_per_unit, tuple(amounts), tuple(energy))
    ledger = Ledger(sum(run.amounts), sum(amounts), run.joules(), result.joules(),
                    amount * run.mass_per_unit, run.amounts[index] * run.mass_per_unit,
                    replacement.energy[0], run.energy[index])
    return result, ledger


@dataclass(frozen=True)
class Snapshot:
    run: Run
    ticks: int
    mass_net: float
    energy_net: float


class Session:
    """Small runtime accounting owner; authored reset starts a fresh ledger."""
    def __init__(self, run):
        self.reset(run)

    def reset(self, authored):
        self.run, self.ticks = authored, 0
        self.mass_net = self.energy_net = 0.

    def snapshot(self):
        return Snapshot(self.run, self.ticks, self.mass_net, self.energy_net)

    def restore(self, state):
        self.run, self.ticks = state.run, state.ticks
        self.mass_net, self.energy_net = state.mass_net, state.energy_net

    def step(self, target, policy="monotone"):
        self.run, transfers, ledger = remap(self.run, target, policy)
        self.ticks += 1
        return transfers, ledger

    def edit(self, index, amount, temperature):
        self.run, ledger = replace_cell(self.run, index, amount, temperature)
        self.mass_net += ledger.mass_in - ledger.mass_out
        self.energy_net += ledger.energy_in - ledger.energy_out
        return ledger
