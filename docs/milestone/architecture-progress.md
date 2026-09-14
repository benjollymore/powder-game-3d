# What the overhaul has established about direction

The useful long-term direction is to retain the paint editor and GPU sandbox while making physical state replaceable behind explicit editing, snapshot and rendering contracts. The evidence does not justify replacing Godot, nor does it justify treating the existing four-byte cellular record as the permanent simulation architecture. These are different decisions.

This is an interpretation of the bounded experiments below, not a claim that a combined high-fidelity solver has been built. The [original assessment](architecture-feasibility.md) preserves the source inventory and proposed larger experiments; individual reports preserve their actual scope and measurements.

| Area | Evidence obtained | Consequence for the architecture |
| --- | --- | --- |
| Editor | Regional Undo/Redo, ordered paint commands, exact Build→Test→Return, validated authored files and normal-input workflow checks work against the current solver. | Keep investing in the editor. A future physical subsystem must participate in the same transaction and snapshot boundaries; it cannot silently add state that Undo or Return omits. |
| Rendering | Physical sprite capacity and reconstructed liquid surfaces can omit existing material. Coverage and optical-path probes distinguish those errors from physical loss. | Treat material representation as a contract with measurable coverage, clipping and interfaces. Cosmetic particles must stay separate from physical material. Coarse fallback restores coverage but does not establish final fidelity. |
| Heat | Stationary enthalpy kernels preserve the declared numerical properties; caching temperature offers a measured memory/time compromise. | Total energy and material-specific mass are authoritative; decoded temperature and phase can be derived. Stationary results do not establish transport through moving material. |
| Transport | Two conservative donor routes produce different temperatures for the exact same current hydro amount update. | An extra temperature texture alone is insufficient. Amount and enthalpy must share accepted transfers or a deliberately chosen mixing rule, plus explicit source and removal accounting. |
| Momentum | Tiny moving FP32 APIC fixtures track the binary64 method and retain angular momentum; PIC loses rotation. Both dissipate substantial non-affine motion in the tested transfer-heavy clouds. | Particle velocity and affine state are credible candidates for mobile material. They still need forces, boundaries and a material model; this is not yet fluid simulation or rigid construction. |
| Performance | Ordinary editor scheduling meets its configured tick rates in the tested short scenes; a 256³ reservoir costs more than the small bowl. Thermal candidates alone consume a substantial frame budget. | Budget the combined editor, renderer, physics and required substeps. Independently fast components do not prove the full combination fits. Sparse/incremental work remains a separate experiment. |

The near-term product remains a bounded paint-and-sim sandbox: understandable placement, reliable gestures, recoverable authored work, readable physical material and predictable Run/Return. That provides a usable comparison while deeper physical experiments proceed. The WorldPainter-inspired paint workflow and Besiege-inspired separation of construction from simulation do not depend on keeping the current cellular rules forever.

For the physical architecture, preserve three explicit boundaries:

1. **Accepted edits:** a command either changes a documented region/state set or reports why it could not. Its inverse covers all authoritative fields. Rendering work can be combined; accepted physical edits and updates cannot be dropped or reordered arbitrarily.
2. **Authored versus runtime state:** authored files define reproducible starting conditions. Runtime snapshots also retain evolving solver state, ordering and accounting. Saving the original build during a live experiment must remain intentional and visible.
3. **Physical state versus appearance:** reconstruct surfaces and instances from authoritative material. Capacity limits, cutaways and picture-quality choices must not remove material from the solver or make it impossible to see and edit without an explicit representation policy.

Rigid assemblies remain a distinct, unproven lane. Connected structures need body-local geometry, mass/inertia and constraints; moving boundaries must exchange impulses without overwriting fluid mass. The current APIC experiment has no rigid bodies, contact or pressure. A force-free initially rotating cloud is not a rigid object.

The next architectural decision should follow discriminating coupled experiments, not a large rewrite: establish force/boundary accounting for moving particles; establish same-liquid mass/enthalpy transport; then measure a candidate material model and its editor/snapshot integration. Keep the cellular implementation available as a regression baseline until a replacement proves the behavior it is meant to improve.

Evidence: [editor workflow](editor-workflow.md), [regional history](editor-redo.md), [pending paint](pending-paint.md), [material capacity](material-capacity.md), [interfaces](material-interface.md), [stationary thermal comparison](thermal-cached.md), [enthalpy transport](enthalpy-transport.md), [finite particle motion](momentum-motion.md), [ordinary scheduling](editor-scheduling.md), [picture quality](display-quality.md).
