extends RefCounted
## Fractional rate accumulator. Catch-up is bounded to avoid a paint burst after
## a suspended window; ordinary 15–240 FPS traces retain the same stamp count.
const RATE := 24.0
const MAX_PER_FRAME := 4
const MAX_DELTA := 0.25
var fraction := 0.0

func reset() -> void:
	fraction = 0.0

func advance(delta: float) -> int:
	if not is_finite(delta) or delta <= 0.0:
		return 0
	fraction += minf(delta, MAX_DELTA) * RATE
	var due := int(floor(fraction + 0.0000001))
	fraction -= due
	return mini(due, MAX_PER_FRAME)
