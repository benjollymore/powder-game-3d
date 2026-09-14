#!/usr/bin/env python3
"""Run visible editor scenarios serially with normal time scheduling and bounded logs."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--grids", nargs="+", type=int, choices=[128, 256], default=[128, 256])
    parser.add_argument("--scenarios", nargs="+", default=["bowl", "Dam break", "Forest fire"])
    parser.add_argument("--seconds", type=float, default=20.0)
    parser.add_argument("--uncapped", action="store_true", help="disable VSync instead of ordinary play pacing")
    parser.add_argument("--surface-hover", action="store_true", help="warp cursor over the world and exercise live surface readbacks")
    parser.add_argument("--output", default="docs/milestone/soak-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S"))
    args = parser.parse_args()
    if not 2 <= args.seconds <= 600:
        parser.error("seconds must be between 2 and 600")
    out = ROOT / args.output
    if out.exists() and any(out.iterdir()):
        parser.error("output must be empty; preserve earlier measurements in their own directory")
    out.mkdir(parents=True, exist_ok=True)
    records = []
    for grid in args.grids:
        for scenario in args.scenarios:
            name = f"grid-{grid}-" + scenario.lower().replace(" ", "-")
            case_dir = out / name
            case_dir.mkdir()
            command = ["godot", "--path", str(ROOT), "--always-on-top", "--resolution", "1600x900"]
            if args.uncapped:
                command.append("--disable-vsync")
            command += ["-s", "res://tools/milestone/editor_soak.gd", "--", f"grid={grid}",
                        f"seconds={args.seconds}", "scenario=" + scenario, "output_dir=" + str(case_dir)]
            if args.surface_hover:
                command.append("surface_hover=1")
            started = time.monotonic()
            print("START " + name, flush=True)
            try:
                process = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                                         stderr=subprocess.STDOUT, text=True, timeout=args.seconds + 120)
                output, code = process.stdout, process.returncode
            except subprocess.TimeoutExpired as exc:
                output = exc.stdout or ""
                if isinstance(output, bytes):
                    output = output.decode(errors="replace")
                output += "\nSOAK COORDINATOR WATCHDOG TIMEOUT\n"
                code = 124
            (case_dir / "run.log").write_text(output)
            result_path = case_dir / "result.json"
            result = json.loads(result_path.read_text()) if result_path.exists() else {}
            ok = (code == 0 and "Editor soak: 1 checks, 0 failures" in output
                  and "ERROR:" not in output and result.get("authored_return_exact") is True)
            record = {"name": name, "pass": ok, "exit": code,
                      "process_seconds": round(time.monotonic() - started, 2),
                      "command": command, "result": result}
            records.append(record)
            (out / "results.json").write_text(json.dumps(records, indent=2) + "\n")
            print(json.dumps({key: value for key, value in record.items() if key not in ("result", "command")}), flush=True)
            if not ok:
                print(output[-5000:], flush=True)
                return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
