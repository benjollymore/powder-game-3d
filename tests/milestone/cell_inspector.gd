extends SceneTree
## Hover inspector wording from probe records, headless.
const Inspector := preload("res://scripts/editor/cell_inspector.gd")
var checks := 0
var failures := 0
func _initialize() -> void:
	call_deferred("run")
func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)
	print("%s: %s" % ["ok" if ok else "FAIL", message])
func probe(id: int, kelvin: float, amount := 0, flags := 0, pos := Vector3i(4, 5, 6)) -> Dictionary:
	return {"pos": pos, "element": id, "temperature": kelvin, "amount": amount, "flags": flags}
func run() -> void:
	check(Inspector.describe(probe(Elements.Id.WATER, 342.15, 200)) == "Water · 69 °C · full", "a full water cell reads name, Celsius and full")
	check(Inspector.describe(probe(Elements.Id.WATER, 293.15, 100)) == "Water · 20 °C · 50%", "a half cell reads its percentage")
	check(Inspector.describe(probe(Elements.Id.WATER, 293.15, 255)) == "Water · 20 °C · compressed", "an over-full cell reads compressed")
	check(Inspector.describe(probe(Elements.Id.OIL, 293.15, 50, 1)) == "Oil · 20 °C · 25% · falling", "the falling flag is spelled out")
	check(Inspector.describe(probe(Elements.Id.SAND, 293.149)) == "Sand · 20 °C", "non-liquids show no amount")
	check(Inspector.describe(probe(Elements.Id.FIRE, 1200.0)) == "Fire · 927 °C", "hot cells round to whole degrees")
	check(Inspector.describe(probe(Elements.Id.WALL, 173.15)) == "Wall · -100 °C", "cold cells read negative Celsius")
	check(Inspector.describe(probe(Elements.Id.AIR, 293.15)) == "", "air is nothing to inspect")
	check(Inspector.describe(probe(Elements.Id.SAND, 293.15, 0, 0, Vector3i(-1, -1, -1))) == "", "a miss reads empty")
	check(Inspector.describe({}) == "" and Inspector.describe(probe(Elements.count() + 3, 300.0)) == "", "malformed or unknown records read empty")
	check(Inspector.celsius(273.15) == 0 and Inspector.celsius(273.65) == 1 and Inspector.celsius(272.6) == -1, "rounding is to the nearest degree")
	print("Cell inspector CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
