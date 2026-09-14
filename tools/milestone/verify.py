#!/usr/bin/env python3
"""Run bounded, sequential Godot checks. GPU mode needs a visible idle GPU.

Run the project import first. Nonzero failures and script/runtime errors fail
even when Godot exits with code zero. Evidence goes in a distinct directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
CPU = [
    ("unit", "tests/unit/run_unit.gd", 128),
    ("gestures", "tests/discovery/gesture_routing.gd", 128),
    ("editing-unit", "tests/milestone/editing_unit.gd", 128),
    ("paint-tools", "tests/milestone/paint_tools.gd", 128),
    ("time-controls", "tests/milestone/test_time_controls.gd", 128),
    ("gpu-profile", "tests/milestone/gpu_profile.gd", 128),
    ("editor-keyboard", "tests/milestone/editor_keyboard.gd", 128),
    ("history-guards", "tests/milestone/history_guards.gd", 128),
    ("pending-gesture", "tests/milestone/pending_gesture.gd", 128),
    ("surface-feedback", "tests/milestone/surface_feedback.gd", 128),
    ("archive-format", "tests/milestone/world_archive.gd", 128),
    ("archive-job", "tests/milestone/archive_job.gd", 128),
    ("archive-panel", "tests/milestone/archive_panel.gd", 128),
]
GPU = [
    ("physics128", "tests/gpu/run_gpu_tests.gd", 128),
    ("regional256", "tests/milestone/regional_undo_gpu.gd", 256),
    ("cadence128", "tests/milestone/batch_cadence.gd", 128),
    ("reset128", "tests/milestone/presentation_reset.gd", 128),
    ("sources128", "tests/milestone/live_emitter.gd", 128),
    ("clicks128", "tests/milestone/live_click.gd", 128),
    ("surface128", "tests/milestone/surface_pick_gpu.gd", 128),
    ("live-input128", "tests/milestone/live_paint_input_gpu.gd", 128),
    ("archives128", "tests/milestone/archive_editor_gpu.gd", 128),
    ("actions128", "tests/milestone/editor_actions_gpu.gd", 128),
    ("editor128", "tests/discovery/interaction_gpu.gd", 128),
    ("trackpad128", "tests/discovery/trackpad_gpu.gd", 128),
    ("phase128", "tests/milestone/test_time_gpu.gd", 128),
    ("preparation128", "tests/milestone/render_preparation.gd", 128),
    ("preparation-render128", "tests/milestone/prepare_capture.gd", 128),
    ("leaf128", "tests/milestone/leaf_finite.gd", 128),
    ("capacity128", "tests/milestone/material_capacity_gpu.gd", 128),
    ("proxy-geometry128", "tests/milestone/material_proxy_geometry_gpu.gd", 128),
    ("proxy-interface128", "tests/milestone/material_proxy_interface_gpu.gd", 128),
    ("workflow128", "tests/milestone/editor_workflow_gpu.gd", 128),
    ("gui-crossing128", "tests/milestone/editor_gui_crossing_gpu.gd", 128),
    ("pending-paint128", "tests/milestone/pending_paint_gpu.gd", 128),
    ("pending-paint256", "tests/milestone/pending_paint_gpu.gd", 256),
    ("redo128", "tests/milestone/editor_redo_gpu.gd", 128),
    ("redo256", "tests/milestone/editor_redo_gpu.gd", 256),
    ("surface-feedback128", "tests/milestone/surface_feedback_gpu.gd", 128),
    ("surface-feedback256", "tests/milestone/surface_feedback_gpu.gd", 256),
    ("surfaces-render128", "tests/milestone/render_surface_gpu.gd", 128),
    ("sprites-render128", "tests/milestone/render_section_sprites_gpu.gd", 128),
    ("liquid-render128", "tests/milestone/render_liquid_section_gpu.gd", 128),
    ("liquid-edges128", "tests/milestone/render_liquid_edges_gpu.gd", 128),
]


def passed(output: str, returncode: int) -> bool:
    summaries = re.findall(r"(?:\b(\d+) failures\b(?!=)|\bfailures=(\d+)\b|\bFAILURES (\d+)\b)", output)
    return (returncode == 0 and bool(summaries)
            and all(int(next(value for value in group if value)) == 0 for group in summaries)
            and not re.search(r"SCRIPT ERROR:|^ERROR:|\bFAIL:", output, re.M))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gpu", action="store_true", help="GPU suites instead of CPU suites")
    parser.add_argument("--only", nargs="+", help="run named suites from the selected set")
    parser.add_argument("--output", default="docs/milestone/verification", help="repository-relative evidence directory")
    args = parser.parse_args()
    cases = GPU if args.gpu else CPU
    if args.only:
        unknown = set(args.only) - {case[0] for case in cases}
        if unknown:
            parser.error("Unknown suites: " + ", ".join(sorted(unknown)))
        cases = [case for case in cases if case[0] in args.only]
    out = ROOT / args.output
    out.mkdir(parents=True, exist_ok=True)
    records = []
    for name, script, grid in cases:
        command = ["godot", "--path", str(ROOT)]
        command += (["--always-on-top", "--disable-vsync", "--resolution", "1600x900"]
                    if args.gpu else ["--headless"])
        command += ["-s", "res://" + script, "--", f"grid={grid}", "output_dir=" + str(out / name)]
        start = time.monotonic()
        try:
            process = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, timeout=120)
            output, code = process.stdout, process.returncode
        except subprocess.TimeoutExpired as exc:
            output = exc.stdout or ""
            if isinstance(output, bytes):
                output = output.decode(errors="replace")
            output += "\nCOORDINATOR WATCHDOG TIMEOUT\n"
            code = 124
        (out / f"{name}.log").write_text(output)
        record = {"name": name, "pass": passed(output, code), "exit": code,
                  "seconds": round(time.monotonic() - start, 2), "command": command}
        records.append(record)
        print(json.dumps(record), flush=True)
        if not record["pass"]:
            print(output[-5000:], flush=True)
            break
    label = "gpu-results" if args.gpu else "cpu-results"
    if args.only:
        # A focused rerun must not erase the manifest of an earlier full run.
        label += "-" + hashlib.sha256("\n".join(case[0] for case in cases).encode()).hexdigest()[:8]
    (out / (label + ".json")).write_text(json.dumps(records, indent=2) + "\n")
    return 0 if len(records) == len(cases) and all(row["pass"] for row in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
