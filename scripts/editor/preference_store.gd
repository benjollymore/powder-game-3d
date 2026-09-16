extends RefCounted
## The one place that decides where editor preferences are stored.
##
## Preferences belong to the person playing. A test run must not be able to
## change them, and twice now one has: a suite toggled fly navigation, saved,
## and the value landed in the real config, so the editor started with the
## option off and looked broken. Saving and restoring the file around each
## suite would not fix it, because our harness kills a suite that exceeds its
## watchdog and we have had crashes; a restore that does not run is no
## protection at all.
##
## So the real file is unreachable from a test by construction. The editor is
## launched as a scene (`godot --path .`); every suite and every headless tool
## is launched as a script (`godot -s res://...`). Script mode therefore
## resolves to a separate file that nothing outside the tests reads, with no
## cleanup to forget and nothing to restore after a crash. `prefs=` overrides
## both, for a tool that wants a specific location.
const REAL := "user://editor_preferences.cfg"
## Distinct from REAL, and deliberately fixed rather than per-process: suites
## run serially, and a stable name leaves one inspectable file instead of a
## litter of them.
const SANDBOX := "user://test-preferences.cfg"


## True when this process was started to run a script rather than the game.
static func is_script_run() -> bool:
	var arguments := OS.get_cmdline_args()
	return arguments.has("-s") or arguments.has("--script")


static func path() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("prefs="):
			return argument.trim_prefix("prefs=")
	return SANDBOX if is_script_run() else REAL
