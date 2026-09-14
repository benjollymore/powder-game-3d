"""Quantify fused-vs-stored-face differences without claiming cross-kernel identity."""
import argparse
import json
from pathlib import Path

DIRECTORY = Path(__file__).resolve().parents[3] / "docs/milestone/evidence-thermal-gpu"


def main(first="baseline", second="fused"):
    prefix = second + "-" if second in ["reuse", "cached"] else ""
    variants = [json.loads((DIRECTORY / f"{v}-results.json").read_text()) for v in [first, second]]
    assert len(variants[0]["cases"]) == len(variants[1]["cases"]) == 12
    assert all(v["failures"] == 0 and v["checks"] > 0 for v in variants)
    metrics = []
    for baseline, fused in zip(variants[0]["cases"], variants[1]["cases"]):
        assert baseline["name"] == fused["name"]
        assert len(baseline["snapshots"]) == len(fused["snapshots"]) > 0
        exact_energy = exact_state = 0
        max_e = max_t = max_f = 0.
        for a, b in zip(baseline["snapshots"], fused["snapshots"]):
            assert a["ticks"] == b["ticks"]
            assert len(a["energy"]) == len(b["energy"]) > 0
            assert len(a["state"]) == len(b["state"]) > 0
            exact_energy += a["energy_hash"] == b["energy_hash"]
            exact_state += a["state_hash"] == b["state_hash"]
            max_e = max(max_e, max(abs(x-y) for x, y in zip(a["energy"], b["energy"])))
            max_t = max(max_t, max(abs(x-y) for x, y in zip(a["state"][::2], b["state"][::2])))
            max_f = max(max_f, max(abs(x-y) for x, y in zip(a["state"][1::2], b["state"][1::2])))
        metric = dict(name=baseline["name"], checkpoints=len(baseline["snapshots"]),
                      exact_energy_checkpoints=exact_energy, exact_state_checkpoints=exact_state,
                      maximum_cell_energy_difference_J=max_e, maximum_temperature_difference_K=max_t,
                      maximum_fraction_difference=max_f)
        metrics.append(metric)
        print("COMPARE", json.dumps(metric, sort_keys=True))
    (DIRECTORY / (prefix + "comparison.json")).write_text(json.dumps(metrics, indent=2)+"\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--first", choices=["baseline", "fused", "reuse"], default="baseline")
    parser.add_argument("--second", choices=["fused", "reuse", "cached"], default="fused")
    args = parser.parse_args()
    main(args.first, args.second)
