# Mac trackpad controls

The discovery editor supports navigation without a physical right mouse button or scroll wheel. Painting remains the default primary drag action; no project-wide input setting changed.

| Action | Trackpad | Mouse / visible alternative |
| --- | --- | --- |
| Paint | Primary click and drag | Left drag |
| Orbit | Two-finger swipe; Option + primary drag | Right drag |
| Pan | Shift + two-finger swipe; Option + Shift + primary drag | Shift + right drag |
| Zoom | Pinch open to approach, closed to retreat | Wheel; Zoom −/+ buttons |
| Center view | Center button / V; F for angled view | Same |
| Move construction plane | Plane −/+ buttons, numeric cell field | Shift-wheel |

The controls are shown in the editor. The tool panel scrolls when needed and fits within a 1280×800 window. Gestures over that panel cannot orbit or zoom the camera. Wheel input over brush/depth controls remains with the GUI, and numeric text editing retains its existing GUI input priority.

An Option-drag captures its navigation mode until the initiating button is released, even if the modifier is released first. Releasing over the toolbar or losing application focus ends navigation. Native gestures terminate an active paint stroke and never create a paint transaction. Painting resumes only with a fresh primary press; this avoids a trailing accidental paint stroke after navigating. Navigation drags pause while the pointer is over the tool panel.

Pinch uses Godot's multiplicative magnification factor, with camera distance clamped to 0.7–4 box widths. Orbit pitch and pan travel are bounded; Center/V and F recover the world after panning. Wheel zoom respects fractional precision. Shift-wheel accumulates fractional units into whole cell steps, resets its remainder after an idle gap or other interaction, and discards overscroll at world boundaries. Native Shift-swipe is **pan**, while Shift-wheel retains the pre-existing depth control; explicit plane −/+ buttons provide the predictable trackpad depth action.

Godot exposes native swipe and pinch through [InputEventPanGesture](https://docs.godotengine.org/en/stable/classes/class_inputeventpangesture.html) and [InputEventMagnifyGesture](https://docs.godotengine.org/en/stable/classes/class_inputeventmagnifygesture.html). Precise wheel amounts are provided by [InputEventMouseButton.factor](https://docs.godotengine.org/en/stable/classes/class_inputeventmousebutton.html#class-inputeventmousebutton-property-factor). Its [macOS 4.6.3 backend](https://github.com/godotengine/godot/blob/4.6.3-stable/platform/macos/godot_content_view.mm) emits pan gestures for phase-based native scrolling and magnification factors for pinch; fallback scrolling can arrive as wheel events. Gesture availability and direction depend on macOS/device settings, and system-reserved gestures may be intercepted before the app receives them. Option-drag and visible buttons work without native gesture recognition. No macOS preference changes are required by this implementation.

## Validation

On Godot 4.6.3 / Apple M5 Pro / Metal at 1280×800, the new injected-event harness passed **27 checks**, including actual Viewport routing, panel isolation, factor/clamp behavior, navigation release/focus handling, unchanged GPU material bytes throughout navigation, and ordinary painting after navigation. The existing interaction harness passed **19 checks**, and the existing geometry/time unit harness passed **20 checks**. These are automated event and GPU-state checks, **not physical trackpad testing or a sensitivity/usability assessment**. Sensitivity should be evaluated on the user's actual trackpad.

```sh
godot --path . res://scenes/discovery/interaction.tscn -- grid=128
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/discovery/trackpad_gpu.gd -- grid=128
godot --path . --resolution 1280x800 --always-on-top --disable-vsync -s res://tests/discovery/interaction_gpu.gd -- grid=128
godot --headless --path . -s res://tests/discovery/interaction_unit.gd
```

The new harness has a 45-second watchdog. Its injected wheel events include both press and release, matching the native backend; omitting release creates artificial GUI capture and invalidates subsequent primary-click tests. The original interaction harness rewrites its historical PNG captures; retain those historical files when rerunning only an input regression. No simulation or renderer behavior was changed for this task.
