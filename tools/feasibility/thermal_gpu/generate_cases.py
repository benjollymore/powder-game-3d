"""Generate binary64 CPU-reference fixtures for an isolated FP32 GPU experiment."""
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from tools.feasibility.thermal_reference import Grid, Material, Parcel

A = Material("synthetic A", 1000, 10, 1000, 1000, 1000)
B = Material("synthetic B", 2000, 20, 2000, 2000, 1000)
PCM = Material("synthetic PCM", 1000, 10, 1000, 2000, 300, 100000)
INSULATOR = Material("synthetic insulator", 1000, 0, 1000, 1000, 1000)


def case(name, shape, dx, materials, ids, temperatures, steps, safety=0.5,
         dt=None, checkpoints=None, fractions=None, analytic=None):
    fractions = fractions or [0] * len(ids)
    cells = [Parcel.at_temperature(materials[m], materials[m].density * dx**3, t, f)
             for m, t, f in zip(ids, temperatures, fractions)]
    grid = Grid(shape, dx, cells)
    bound = grid.stable_dt()
    dt = dt if dt is not None else (safety * bound if math.isfinite(bound) else 1)
    result = dict(name=name, shape=shape, dx=dx, material_ids=ids, initial_energy=[c.energy for c in cells],
                  materials=[[m.density, m.conductivity, m.cp_solid, m.cp_liquid, m.melting_kelvin,
                              m.latent_heat, m.solid_at_melt, 0] for m in materials],
                  stable_dt=bound if math.isfinite(bound) else 1e30, dt=dt, steps=steps, snapshots=[])
    for target in checkpoints or [steps]:
        grid.advance(target - grid.ticks, dt)
        result["snapshots"].append(dict(tick=target, energy=[c.energy for c in cells],
                                        temperature=[c.state()[0] for c in cells],
                                        fraction=[c.state()[1] for c in cells]))
    if analytic is not None:
        result["analytic_temperature"] = analytic
    return result


def build():
    cases = []
    cases.append(case("hotspot_3d", [3, 3, 3], .01, [A], [0]*27,
                      [400 if i == 13 else 300 for i in range(27)], 1))
    ids = [0 if x < 4 else 1 for z in range(4) for y in range(4) for x in range(8)]
    cases.append(case("interface_3d", [8, 4, 4], .01, [A, B], ids,
                      [400 if m == 0 else 300 for m in ids], 1000, safety=.8,
                      checkpoints=[1, 10, 100, 1000]))
    cases.append(case("below_reference", [4, 2, 2], .01, [A], [0]*16,
                      [250 if i%4 < 2 else 270 for i in range(16)], 500))
    cases.append(case("equilibrium_3d", [8, 8, 8], .01, [A], [0]*512, [350]*512, 1000))
    cases.append(case("conducting_phase", [2, 1, 1], .01, [PCM], [0, 0], [290, 360], 300,
                      checkpoints=[1, 2, 4, 8, 16, 32, 64, 128, 300]))
    # k=0 isolates state reconstruction throughout the latent interval.
    latent = Material("insulated synthetic PCM", 1000, 0, 1000, 2000, 300, 100000)
    cases.append(case("latent_plateau", [13, 1, 1], .01, [latent], [0]*13,
                      [290]+[300]*11+[310], 20, fractions=[0]+[i/10 for i in range(11)]+[1]))
    cases.append(case("insulated_interface", [2, 1, 1], .01, [A, INSULATOR], [0, 1], [400, 300], 1000))
    diffusion = Material("synthetic diffusion", 1000, 100, 1000, 1000, 1000)
    for n in [16, 32, 64]:
        dx, duration = .1/n, 1.
        averaging = math.sin(math.pi/(2*n))/(math.pi/(2*n))
        initial = [350+20*averaging*math.cos(math.pi*(i+.5)/n) for i in range(n)]
        alpha = diffusion.conductivity/(diffusion.density*diffusion.cp_solid)
        dt_max = dx*dx/(2*alpha)
        steps = math.ceil(duration/(.5*dt_max))
        exact = [350+(t-350)*math.exp(-alpha*(math.pi/.1)**2*duration) for t in initial]
        cases.append(case(f"diffusion_{n}", [n, 1, 1], dx, [diffusion], [0]*n, initial,
                          steps, dt=duration/steps, analytic=exact))
    cases.append(case("batch_phase", [4, 2, 2], .01, [PCM], [0]*16,
                      [290+(i%4)*20 for i in range(16)], 80, safety=.8))
    return {"schema": 1, "units": "SI; full stationary insulated cubic cells", "cases": cases}


if __name__ == "__main__":
    output = ROOT / "tests/feasibility/thermal_gpu/cases.json"
    output.write_text(json.dumps(build(), indent=2, allow_nan=False)+"\n")
    print(output)
