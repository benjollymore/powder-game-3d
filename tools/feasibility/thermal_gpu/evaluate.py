"""Compare real GPU readbacks against generated binary64 finite-volume fixtures.

Acceptance targets declared before running the GPU: 0.005 K state error,
1e-5 phase-fraction error, 2e-5 energy drift relative to initial |energy| sum;
cosine refinement retains the CPU reference's >3x reduction per doubling.
These are experiment criteria, not production material accuracy guarantees.
"""
import argparse
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "tests/feasibility/thermal_gpu/cases.json"
RESULTS = ROOT / "docs/milestone/evidence-thermal-gpu/results.json"


def evaluate(prefix=""):
    results_path = RESULTS.parent / (prefix + "results.json")
    fixtures = {c["name"]: c for c in json.loads(FIXTURES.read_text())["cases"]}
    actual = json.loads(results_path.read_text())
    failures, metrics, diffusion = [], [], []
    names = [c["name"] for c in actual["cases"]]
    if set(names) != set(fixtures) or len(names) != len(fixtures):
        failures.append("Missing, duplicated or unexpected GPU fixture results")
    if actual["checks"] <= 0 or actual["failures"] or actual["batch_equal"] != [True, True, True]:
        failures.append("GPU admission/batching checks failed")
    for measured in actual["cases"]:
        case = fixtures[measured["name"]]
        if len(measured["snapshots"]) != len(case["snapshots"]):
            failures.append(f"{case['name']}: missing checkpoint results")
        initial = measured["initial"]["energy"]
        initial_total = math.fsum(initial)
        energy_scale = max(math.fsum(abs(e) for e in initial), 1e-30)
        max_t, max_f, max_drift, max_energy_error = 0., 0., 0., 0.
        plateau_samples = 0
        for expected, state in zip(case["snapshots"], measured["snapshots"]):
            if state["ticks"] != expected["tick"]:
                failures.append(f"{case['name']}: checkpoint tick mismatch")
            energy, packed = state["energy"], state["state"]
            if len(energy) != len(initial) or len(packed) != len(initial)*2 or not all(map(math.isfinite, energy+packed)):
                failures.append(f"{case['name']}: nonfinite or malformed state")
                continue
            temperatures, fractions = packed[::2], packed[1::2]
            max_t = max(max_t, max(abs(a-b) for a, b in zip(temperatures, expected["temperature"])))
            max_f = max(max_f, max(abs(a-b) for a, b in zip(fractions, expected["fraction"])))
            max_drift = max(max_drift, abs(math.fsum(energy)-initial_total)/energy_scale)
            max_energy_error = max(max_energy_error, max(abs(a-b) for a, b in zip(energy, expected["energy"])))
            for i, (temp, fraction) in enumerate(zip(temperatures, expected["fraction"])):
                material = case["materials"][case["material_ids"][i]]
                if material[5] > 0 and 1e-4 < fraction < .9999:
                    plateau_samples += 1
                    if temp != material[4]:
                        failures.append(f"{case['name']}: latent interval not exactly at melting temperature")
            initial_t = measured["initial"]["state"][::2]
            if min(temperatures) < min(initial_t)-.005 or max(temperatures) > max(initial_t)+.005:
                failures.append(f"{case['name']}: explicit update exceeds initial temperature range")
        if max_t > .005 or max_f > 1e-5 or max_drift > 2e-5:
            failures.append(f"{case['name']}: numerical acceptance target exceeded")
        metric = dict(name=case["name"], steps=case["steps"], dt=case["dt"], stable_dt=case["stable_dt"],
                      max_temperature_error_K=max_t, max_fraction_error=max_f,
                      energy_relative_drift=max_drift, max_cell_energy_error_J=max_energy_error,
                      final_energy_drift_J=math.fsum(measured["snapshots"][-1]["energy"])-initial_total,
                      plateau_samples=plateau_samples)
        if "analytic_temperature" in case:
            temperatures = measured["snapshots"][-1]["state"][::2]
            rms = math.sqrt(math.fsum((a-b)**2 for a, b in zip(temperatures, case["analytic_temperature"]))/len(temperatures))
            metric["analytic_rms_K"] = rms
            diffusion.append(rms)
        metrics.append(metric)
    ratios = [a/b for a, b in zip(diffusion, diffusion[1:])]
    if len(ratios) != 2 or any(r <= 3 for r in ratios) or diffusion[-1] >= .001:
        failures.append("FP32 diffusion did not retain the CPU reference's convergence targets")
    if not any(m["plateau_samples"] for m in metrics if m["name"] == "conducting_phase"):
        failures.append("No phase plateau was observed during conduction")
    report = dict(metrics=metrics, diffusion_refinement_ratios=ratios, failures=failures)
    (RESULTS.parent / (prefix + "metrics.json")).write_text(json.dumps(report, indent=2)+"\n")
    for m in metrics:
        print(f"METRIC {m['name']} steps={m['steps']} temperature_error_K={m['max_temperature_error_K']:.9g} fraction_error={m['max_fraction_error']:.9g} energy_drift_relative={m['energy_relative_drift']:.9g} drift_J={m['final_energy_drift_J']:.9g} plateau_samples={m['plateau_samples']}")
    print(f"DIFFUSION rms_K={diffusion} refinement_ratios={ratios}")
    print(f"THERMAL_NUMERICS failures={len(failures)}")
    for failure in failures:
        print("FAIL:", failure)
    return len(failures)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--variant", choices=["baseline", "fused", "reuse"])
    args = parser.parse_args()
    raise SystemExit(bool(evaluate(args.variant + "-" if args.variant else "")))
