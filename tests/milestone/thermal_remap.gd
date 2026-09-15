extends SceneTree
## CPU oracle for the hydro thermal remap (shaders/compute/hydro.glsl).
##
## Ports the kernel's three-sweep two-cursor walk and checks it against a
## plain segment-list remap (the monotone policy of
## tools/feasibility/enthalpy_remap.py) on fixtures that include top-heavy
## runs up to a full 128-cell pipe, where the donor cursor lags far behind
## the receiver cursor. When python3 is available the Python oracle itself is
## run on the same fixtures.
##   godot --headless --path . -s res://tests/milestone/thermal_remap.gd
const FULL := 200
const MAX_AMOUNT := 255
const COMP := 2
const CAP := 200.0 # capacity per full cell: energy is amount x temperature

var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("%s: %s" % ["ok" if ok else "FAIL", message])

## Port of hydro.glsl profile_column's target amounts (and enthalpy_remap.column_target).
static func column_target(amounts: Array) -> Array:
	var n := amounts.size()
	var mass := 0
	for a in amounts:
		mass += int(a)
	var height := 0
	for h in range(1, n + 1):
		if h * FULL + COMP * h * (h - 1) / 2 > mass:
			break
		height = h
	var remainder := mass - (height * FULL + COMP * height * (height - 1) / 2)
	var extra := 0
	var extra_rem := 0
	if height == n:
		extra = remainder / n
		extra_rem = remainder % n
		remainder = 0
	var result := []
	var carry := 0
	for k in n:
		var want: int
		if k < height:
			want = FULL + COMP * (height - 1 - k) + extra + (1 if k < extra_rem else 0)
		elif k == height:
			want = remainder
		else:
			want = 0
		want += carry
		carry = maxi(want - MAX_AMOUNT, 0)
		result.append(mini(want, MAX_AMOUNT))
	return result

## Plain monotone remap: consecutive mass intervals, proportional energy
## shares, the last segment of a donor carries its remainder.
static func reference_remap(old_amounts: Array, energies: Array, target: Array) -> Array:
	var old := old_amounts.duplicate()
	var need := target.duplicate()
	var segments := []
	for i in old.size():
		segments.append([])
	var donor := 0
	var receiver := 0
	while donor < old.size() and receiver < need.size():
		if old[donor] == 0:
			donor += 1
		elif need[receiver] == 0:
			receiver += 1
		else:
			var units: int = mini(old[donor], need[receiver])
			segments[donor].append([receiver, units])
			old[donor] -= units
			need[receiver] -= units
	var incoming := []
	for j in target.size():
		incoming.append(0.0)
	for i in segments.size():
		var sent := 0.0
		for part in segments[i].size():
			var receiver_index: int = segments[i][part][0]
			var units: int = segments[i][part][1]
			var q: float
			if part == segments[i].size() - 1:
				q = float(energies[i]) - sent
			else:
				q = float(energies[i]) * (float(units) / float(old_amounts[i]))
			sent += q
			incoming[receiver_index] += q
	return incoming

## Port of the three-sweep walk in hydro.glsl (remap_fold / remap_receive /
## remap_finish): donors are read only from data the walk never writes, so it
## is exact for any run length. Returns [energies, ok].
static func streamed_remap(old_amounts: Array, energies: Array, target: Array) -> Array:
	var n := old_amounts.size()
	var r_channel := energies.duplicate() # sweep 0: energy per cell
	var g_channel := []
	for i in n:
		g_channel.append(0.0)
	var rd := -1
	var rd_amount := 0
	var rd_rem := 0
	var rd_energy := 0.0
	var rd_sent := 0.0
	var ok := true
	for k in n: # sweep 1
		var need: int = target[k]
		var e_new := 0.0
		while need > 0:
			if rd_rem == 0:
				rd += 1
				if rd >= n:
					ok = false
					break
				rd_amount = old_amounts[rd]
				rd_energy = r_channel[rd]
				rd_rem = rd_amount
				rd_sent = 0.0
				if rd_rem == 0:
					continue
			var units: int = mini(rd_rem, need)
			var q: float = (rd_energy - rd_sent) if units == rd_rem else rd_energy * (float(units) / float(rd_amount))
			e_new += q
			rd_sent += q
			rd_rem -= units
			need -= units
		g_channel[k] = e_new
	var out := []
	for k in n: # sweep 2
		out.append(g_channel[k] if target[k] > 0 else 0.0)
	return [out, ok]

func energies_at(amounts: Array, temps: Array) -> Array:
	var out := []
	for i in amounts.size():
		out.append(float(amounts[i]) * float(temps[i]))
	return out

func compare(name: String, amounts: Array, temps: Array, target: Array, expect_ok := true) -> void:
	var energies := energies_at(amounts, temps)
	var reference := reference_remap(amounts, energies, target)
	var streamed: Array = streamed_remap(amounts, energies, target)
	var worst := 0.0
	var total_before := 0.0
	var total_after := 0.0
	for i in amounts.size():
		worst = maxf(worst, absf(float(streamed[0][i]) - float(reference[i])))
		total_before += energies[i]
		total_after += float(streamed[0][i])
	check(streamed[1] == expect_ok, "%s: streamed walk %s" % [name, "completes" if expect_ok else "reports a mass mismatch"])
	if expect_ok:
		check(worst <= 1e-9 * maxf(1.0, total_before), "%s: streamed energies match the segment remap (worst %s)" % [name, worst])
		check(absf(total_after - total_before) <= 1e-9 * maxf(1.0, total_before), "%s: energy conserved (%.6f -> %.6f)" % [name, total_before, total_after])
		var hot_stays_low := true
		# Parcel order: with monotone temperatures along the run, the result is monotone too.
		var monotone := true
		for i in range(1, temps.size()):
			if float(temps[i]) > float(temps[i - 1]):
				monotone = false
		if monotone:
			var last := INF
			for i in target.size():
				if target[i] > 0:
					var t: float = float(streamed[0][i]) / float(target[i])
					if t > last + 1e-9:
						hot_stays_low = false
					last = t
			check(hot_stays_low, "%s: a hot bottom stays a hot bottom" % name)

func run() -> void:
	# Hydrostatic settle of a level column.
	compare("uniform column", [200, 200, 200, 200], [350.0, 330.0, 310.0, 300.0], column_target([200, 200, 200, 200]))
	# Water falling onto a shallow pool compresses downward: donors ahead of receivers.
	compare("pour", [60, 200, 200, 200, 90], [340.0, 330.0, 320.0, 310.0, 300.0], column_target([60, 200, 200, 200, 90]))
	# Top-heavy compressed run over tiny cells: the donor cursor lags the receiver cursor.
	var top_heavy := [255, 255, 255, 255, 255, 1, 1]
	compare("top heavy", top_heavy, [400.0, 380.0, 360.0, 340.0, 320.0, 300.0, 290.0], column_target(top_heavy))
	var deep := []
	var deep_t := []
	for i in 10:
		deep.append(255)
		deep_t.append(400.0 - 5.0 * i)
	for i in 5:
		deep.append(1)
		deep_t.append(300.0)
	compare("deep top heavy", deep, deep_t, column_target(deep))
	# Row relaxation: amounts move both ways by half the gap to the mean.
	var row := [240, 100, 180, 60]
	var mean := 145.0
	var relaxed := []
	for a in row:
		relaxed.append(clampi(int(a) + int(round(0.5 * (mean - float(a)))), 1, MAX_AMOUNT))
	var drift := 0
	for i in row.size():
		drift += relaxed[i] - row[i]
	for i in row.size():
		if drift > 0 and relaxed[i] > 1:
			relaxed[i] -= 1
			drift -= 1
		elif drift < 0 and relaxed[i] < MAX_AMOUNT:
			relaxed[i] += 1
			drift += 1
	compare("row relax", row, [310.0, 300.0, 320.0, 305.0], relaxed)
	# Long runs (the reviewer's overflow cases): half a 128 pipe and a full one,
	# top-heavy so the donor cursor lags far behind the receivers.
	var pipe64 := []
	var pipe64_t := []
	for i in 40:
		pipe64.append(255)
		pipe64_t.append(400.0 - float(i))
	for i in 24:
		pipe64.append(3)
		pipe64_t.append(300.0)
	compare("64-cell top-heavy pipe", pipe64, pipe64_t, column_target(pipe64))
	var pipe128 := []
	var pipe128_t := []
	for i in 96:
		pipe128.append(255)
		pipe128_t.append(450.0 - float(i))
	for i in 32:
		pipe128.append(1)
		pipe128_t.append(300.0)
	compare("128-cell top-heavy pipe", pipe128, pipe128_t, column_target(pipe128))
	var row128 := []
	var row128_t := []
	for i in 128:
		row128.append(255 if i % 3 == 0 else 60)
		row128_t.append(300.0 + float(i % 7))
	var mean128 := 0.0
	for a in row128:
		mean128 += float(a)
	mean128 /= 128.0
	var relaxed128 := []
	for a in row128:
		relaxed128.append(clampi(int(a) + int(round(0.5 * (mean128 - float(a)))), 1, MAX_AMOUNT))
	var drift128 := 0
	for i in row128.size():
		drift128 += relaxed128[i] - row128[i]
	for i in row128.size():
		if drift128 > 0 and relaxed128[i] > 1:
			relaxed128[i] -= 1
			drift128 -= 1
		elif drift128 < 0 and relaxed128[i] < MAX_AMOUNT:
			relaxed128[i] += 1
			drift128 += 1
	compare("128-cell row relax", row128, row128_t, relaxed128)

	# Python oracle parity on the same fixtures, when python3 is present.
	var script := """
import json, sys
sys.path.insert(0, '.')
from tools.feasibility.enthalpy_remap import Run, remap, column_target
from tools.feasibility.thermal_reference import Material
m = Material('linear', 1.0, 1.0, 1.0, 1.0, 1.0, 0.0)
cases = json.loads(sys.argv[1])
out = []
for amounts, temps in cases:
    run = Run.at_temperatures(m, 1.0, amounts, temps)
    result, transfers, ledger = remap(run, column_target(amounts), 'monotone')
    out.append(list(result.energy))
print(json.dumps(out))
"""
	var cases := [[[200, 200, 200, 200], [350.0, 330.0, 310.0, 300.0]], [[60, 200, 200, 200, 90], [340.0, 330.0, 320.0, 310.0, 300.0]],
		[top_heavy, [400.0, 380.0, 360.0, 340.0, 320.0, 300.0, 290.0]], [deep, deep_t], [pipe64, pipe64_t], [pipe128, pipe128_t]]
	var output := []
	var script_path := "/tmp/thermal_remap_oracle.py"
	var file := FileAccess.open(script_path, FileAccess.WRITE)
	file.store_string(script)
	file.close()
	var code := OS.execute("python3", [script_path, JSON.stringify(cases)], output, true)
	if code != 0 or output.is_empty():
		print("python3 oracle unavailable (exit %d): %s" % [code, "".join(output)])
		check(true, "python oracle skipped")
	else:
		var parsed = JSON.parse_string(output[0].strip_edges())
		check(parsed is Array and parsed.size() == cases.size(), "python oracle returned one result per case")
		if parsed is Array:
			for c in cases.size():
				var amounts: Array = cases[c][0]
				var temps: Array = cases[c][1]
				var target := column_target(amounts)
				var streamed_c: Array = streamed_remap(amounts, energies_at(amounts, temps), target)
				var worst := 0.0
				for i in amounts.size():
					# Python energies are amount x (T - 273.15); ours are amount x T.
					var python_e := float(parsed[c][i]) + 273.15 * float(target[i])
					worst = maxf(worst, absf(float(streamed_c[0][i]) - python_e))
				check(worst <= 1e-6 * 400.0 * 255.0, "python oracle agrees on case %d (worst %s)" % [c, worst])
	print("Thermal remap CPU: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
