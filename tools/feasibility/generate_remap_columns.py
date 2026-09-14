"""Deterministic column fixtures compared against the real production GPU shader."""
import json
from pathlib import Path
import random
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from tools.feasibility.enthalpy_remap import column_target

rng = random.Random(6543)
arrays = [[100]*3, [200]*3, [255,1,144], [1]*256, [255]*256]
arrays += [[rng.randrange(1,256) for _ in range(n)]
           for n in [1,2,3,7,16,31,63,127,128,129,200,255,256]]
path = ROOT / "tests/feasibility/enthalpy_remap/columns.json"
path.write_text(json.dumps([dict(amounts=a, target=column_target(a)) for a in arrays], indent=2)+"\n")
print(path)
