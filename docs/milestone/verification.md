# Integrated verification record

Coordinator machine: Godot 4.6.3, Metal 4.0 / Forward+, Apple M5 Pro. GPU processes ran sequentially with visible windows and watchdogs. Script/runtime errors were inspected even when Godot returned exit code zero.

## Combined foundation run

The [GPU manifest](combined-evidence/gpu-results.json) records 15 suites, **484 passing checks**. The [CPU manifest](combined-evidence/cpu-results.json) records seven suites, **94 passing checks**. Each suite has its raw log in the same directory; render suites retain images in separate subdirectories.

This run exercised the integrated foundation through authoritative surface editing, tick-owned live input, archives, paint-first controls, and render fixes. It preceded the later pause/step UI, opt-in render coalescing, and lifecycle corrections. It is not represented as a fresh full-suite run of every later commit.

| GPU area | Checks | Grid |
|---|---:|---:|
| Existing physical invariants | 74 | 128³ |
| Regional undo | 17 | 256³ |
| Tick batching / air cadence | 30 | 128³ |
| Reset / paused temporal state | 31 | 128³ |
| Held sources / released clicks | 34 / 19 | 128³ |
| Authoritative surface targeting | 36 | 128³ |
| Live input sampling | 11 | 128³ |
| Archives / queued editor actions | 13 / 11 | 128³ |
| Editing / synthesized trackpad | 20 / 27 | 128³ |
| Surface normals / sprite clipping / liquid depth | 60 / 40 / 61 | 128³ |

## Later targeted runs

The lifecycle corrections committed in `1d2f675` passed [16 archive checks](lifecycle-evidence/archives128.log) and [13 action checks](lifecycle-evidence/actions128.log). They cover modal ownership of global shortcuts, completed live edits invalidating pending Open, repeated queued Run intent, and stale world epochs.

The [phase/preparation manifest](lifecycle-evidence/gpu-results.json) contains three further passing suites: eight live pause/step checks, twelve render-preparation ordering checks, and four actual rendered-image comparisons. The [focused CPU manifest](lifecycle-evidence/cpu-results.json) contains ten gesture, nine paint-tool and nine time-control checks. These overlap earlier coverage and should not be summed as unique tests.

The coordinator independently ran `python3 -m unittest discover -s tests/feasibility -v`: **22 tests passed**, covering the isolated binary64 thermal and PIC/APIC transfer references. [Raw output](lifecycle-evidence/feasibility.log). Neither reference is connected to production physics.

## Reproduction and limits

Import the project first, then use `python3 tools/milestone/verify.py` for CPU suites or `python3 tools/milestone/verify.py --gpu` for sequential visible GPU suites. `--only` selects named cases; `--output` directs logs and images to a separate repository-relative directory. Each process has a 120-second limit. The current default suite includes newer tests beyond the earlier combined run.

Rendered capture tests verify image output; ordinary GPU readback tests verify state. Neither substitutes for physical touchpad testing, native file chooser interaction, or human assessment of casual play. The older deterministic live-input test disables editor processing; the ongoing full workflow harness deliberately keeps it enabled to cover input ownership through the production loop.

Performance evidence lives separately in [editor-performance.md](editor-performance.md). Short functional checks do not establish sustained frame rate or long-session reliability.
