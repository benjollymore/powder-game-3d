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
    ("unit256", "tests/unit/run_unit.gd", 256),
    ("gestures", "tests/discovery/gesture_routing.gd", 128),
    ("editing-unit", "tests/milestone/editing_unit.gd", 128),
    ("interaction-unit", "tests/discovery/interaction_unit.gd", 128),
    ("fly-navigation", "tests/milestone/fly_navigation.gd", 128),
    ("paint-tools", "tests/milestone/paint_tools.gd", 128),
    ("brush-shape", "tests/milestone/brush_shape.gd", 128),
    ("placement-tools", "tests/milestone/placement_tools.gd", 128),
    ("time-controls", "tests/milestone/test_time_controls.gd", 128),
    ("gpu-profile", "tests/milestone/gpu_profile.gd", 128),
    ("editor-keyboard", "tests/milestone/editor_keyboard.gd", 128),
    ("history-guards", "tests/milestone/history_guards.gd", 128),
    ("pending-gesture", "tests/milestone/pending_gesture.gd", 128),
    ("surface-feedback", "tests/milestone/surface_feedback.gd", 128),
    ("archive-format", "tests/milestone/world_archive.gd", 128),
    ("archive-job", "tests/milestone/archive_job.gd", 128),
    ("archive-panel", "tests/milestone/archive_panel.gd", 128),
    ("authored-document", "tests/milestone/authored_document.gd", 128),
    ("file-shortcuts", "tests/milestone/file_shortcuts.gd", 128),
    ("surface-join", "tests/milestone/surface_join.gd", 128),
    ("heat-ui", "tests/milestone/heat_ui.gd", 128),
    ("keep-result", "tests/milestone/keep_result.gd", 128),
    ("cell-inspector", "tests/milestone/cell_inspector.gd", 128),
    ("read-world-fifo", "tests/milestone/read_world_fifo.gd", 128),
    ("examples128", "tests/milestone/examples_cpu.gd", 128),
    ("examples256", "tests/milestone/examples_cpu.gd", 256, 300),
    ("ui-scale", "tests/milestone/ui_scale.gd", 128),
    ("guard-queue", "tests/milestone/guard_queue.gd", 128),
    ("thermal-init", "tests/milestone/thermal_init.gd", 128),
    ("thermal-remap", "tests/milestone/thermal_remap.gd", 128),
]
GPU = [
    ("physics128", "tests/gpu/run_gpu_tests.gd", 128, 300),
    ("regional256", "tests/milestone/regional_undo_gpu.gd", 256),
    ("cadence128", "tests/milestone/batch_cadence.gd", 128),
    ("thermal-state128", "tests/milestone/thermal_state_gpu.gd", 128),
    ("reset128", "tests/milestone/presentation_reset.gd", 128),
    ("sources128", "tests/milestone/live_emitter.gd", 128),
    ("clicks128", "tests/milestone/live_click.gd", 128),
    ("surface128", "tests/milestone/surface_pick_gpu.gd", 128),
    ("brush-shape128", "tests/milestone/brush_shape_gpu.gd", 128),
    ("preview128", "tests/milestone/preview_cells_gpu.gd", 128),
    ("tools128", "tests/milestone/placement_tools_gpu.gd", 128),
    ("live-paint-click128", "tests/milestone/live_paint_click_gpu.gd", 128, 300),
    ("preview-pick128", "tests/milestone/preview_pick_gpu.gd", 128),
    ("live-input128", "tests/milestone/live_paint_input_gpu.gd", 128),
    ("surface-stroke128", "tests/milestone/surface_stroke_gpu.gd", 128),
    ("archives128", "tests/milestone/archive_editor_gpu.gd", 128),
    ("document-protection128", "tests/milestone/document_protection_gpu.gd", 128),
    ("document-protection256", "tests/milestone/document_protection_gpu.gd", 256),
    ("file-shortcuts128", "tests/milestone/file_shortcuts_gpu.gd", 128),
    ("file-shortcuts256", "tests/milestone/file_shortcuts_gpu.gd", 256),
    ("heat-ui128", "tests/milestone/editor_heat_ui_gpu.gd", 128),
    ("archives-thermal128", "tests/milestone/archives_thermal_gpu.gd", 128),
    ("inspector128", "tests/milestone/inspector_gpu.gd", 128),
    ("actions128", "tests/milestone/editor_actions_gpu.gd", 128),
    ("editor128", "tests/discovery/interaction_gpu.gd", 128),
    ("trackpad128", "tests/discovery/trackpad_gpu.gd", 128),
    ("phase128", "tests/milestone/test_time_gpu.gd", 128),
    ("preparation128", "tests/milestone/render_preparation.gd", 128),
    ("preparation-render128", "tests/milestone/prepare_capture.gd", 128),
    ("leaf128", "tests/milestone/leaf_finite.gd", 128),
    ("leaf-exposure128", "tests/milestone/leaf_exposure_gpu.gd", 128),
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
    ("ordinary-geometry128", "tests/milestone/ordinary_liquid_geometry_gpu.gd", 128),
    ("ordinary-interface128", "tests/milestone/ordinary_liquid_interface_gpu.gd", 128),
    ("ordinary-controls128", "tests/milestone/ordinary_liquid_controls_gpu.gd", 128),
    ("ripple128", "tests/milestone/render_powder_ripple_gpu.gd", 128),
    ("submerged-caustic128", "tests/milestone/submerged_caustic_gpu.gd", 128),
    ("palette128", "tests/milestone/palette_capture_gpu.gd", 128),
    ("liquid-base128", "tests/milestone/render_liquid_base_gpu.gd", 128),
    ("examples-look128", "tests/milestone/render_examples_gpu.gd", 128),
    ("ui-scale128", "tests/milestone/ui_scale_gpu.gd", 128, 200),
]


def passed(output: str, returncode: int) -> bool:
    summaries = re.findall(r"(?:\b(\d+) failures\b(?!=)|\bfailures=(\d+)\b|\bFAILURES (\d+)\b)", output)
    return (returncode == 0 and bool(summaries)
            and all(int(next(value for value in group if value)) == 0 for group in summaries)
            and not re.search(r"SCRIPT ERROR:|^ERROR:|\bFAIL:", output, re.M))


# Preferences belong to the person playing, and a suite that writes them makes
# the editor start wrong. The preference layer resolves away from the real file
# in script mode (scripts/editor/preference_store.gd), and this is the check
# that the arrangement actually holds: mechanisms rot, so verify the property.
USER_PREFERENCES = (Path.home() / "Library/Application Support/Godot/app_userdata"
                    / "Powder Game 3D" / "editor_preferences.cfg")


def preferences_fingerprint() -> str:
    if not USER_PREFERENCES.exists():
        return "absent"
    return hashlib.sha256(USER_PREFERENCES.read_bytes()).hexdigest()


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
    preferences_before = preferences_fingerprint()
    for case in cases:
        # A case may carry a fourth element: its own watchdog in seconds. The
        # default suits a suite that runs in well under a minute; building
        # every scenario at 256 legitimately needs longer, and a suite that
        # passes its checks then trips the watchdog on teardown is a false
        # failure that hides real ones.
        name, script, grid = case[0], case[1], case[2]
        watchdog = case[3] if len(case) > 3 else 120
        command = ["godot", "--path", str(ROOT)]
        command += (["--always-on-top", "--disable-vsync", "--resolution", "1600x900"]
                    if args.gpu else ["--headless"])
        command += ["-s", "res://" + script, "--", f"grid={grid}", "output_dir=" + str(out / name)]
        start = time.monotonic()
        try:
            process = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT, text=True, timeout=watchdog)
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
    preferences_after = preferences_fingerprint()
    if preferences_after != preferences_before:
        print(json.dumps({"name": "user-preferences-untouched", "pass": False,
                          "detail": "a suite wrote the real editor preferences",
                          "path": str(USER_PREFERENCES),
                          "before": preferences_before, "after": preferences_after}), flush=True)
        return 1
    return 0 if len(records) == len(cases) and all(row["pass"] for row in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
