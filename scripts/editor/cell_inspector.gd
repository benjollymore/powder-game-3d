extends RefCounted
## Formats one authoritative cell probe for the status line: element name,
## temperature in degrees Celsius and, for liquids, how full the cell is.
## Pure formatting so the CPU suite can pin the wording.

const ZERO_C := 273.15


static func celsius(kelvin: float) -> int:
	return int(round(kelvin - ZERO_C))


static func amount_text(id: int, amount: int) -> String:
	if not Elements.is_liquid(id):
		return ""
	if amount >= Elements.LIQUID_FULL:
		return "full" if amount == Elements.LIQUID_FULL else "compressed"
	return "%d%%" % int(round(100.0 * amount / Elements.LIQUID_FULL))


## `probe` is the dictionary from VoxelSim.request_cell_probe. A miss or an
## air cell reads as nothing to inspect.
static func describe(probe: Dictionary) -> String:
	var pos: Vector3i = probe.get("pos", Vector3i(-1, -1, -1))
	var id: int = probe.get("element", 0)
	if pos.x < 0 or id <= 0 or id >= Elements.count():
		return ""
	var parts: Array[String] = [String(Elements.TABLE[id].name), "%d °C" % celsius(float(probe.get("temperature", ZERO_C)))]
	var amount := amount_text(id, int(probe.get("amount", 0)))
	if not amount.is_empty():
		parts.append(amount)
	if int(probe.get("flags", 0)) & 1:
		parts.append("falling")
	return " · ".join(parts)
