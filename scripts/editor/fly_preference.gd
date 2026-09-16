extends RefCounted
## Whether WASD fly navigation is on, remembered beside the picture preference
## in the same user config file (scripts/editor/display_preferences.gd).
##
## Fly navigation was introduced as an opt-in and is now on by default: with
## the window focused, W A S D Q E fly the camera unless the option is turned
## off. Changing the default alone would not reach anyone whose config already
## holds a value, and a stored `false` written while the feature was opt-in is
## not a decision to fly less: it is the old default, or the editor's own
## bookkeeping, written back verbatim.
##
## So the preference moved to its own key. `camera/fly` can only have been
## written before the change and is ignored; `camera/fly_always_v2` can only
## have been written after it and is honoured, including an explicit `false`.
## A user who turns the option off from now on keeps it off.
const PATH := "user://editor_preferences.cfg"
const SECTION := "camera"
const KEY := "fly_always_v2"
const LEGACY_KEY := "fly"
## On unless this version of the preference says otherwise.
const DEFAULT := true


static func load_enabled() -> bool:
	var config := ConfigFile.new()
	config.load(PATH)
	# A `null` default counts as "no default given" and logs an error, so ask
	# whether the key exists rather than reading it blind: on a fresh install,
	# and on a config written before this key existed, it does not.
	if not config.has_section_key(SECTION, KEY):
		return DEFAULT
	var saved: Variant = config.get_value(SECTION, KEY, DEFAULT)
	return saved if saved is bool else DEFAULT


## A preference that cannot be written still applies to this session; the
## editor says so rather than silently reverting the toggle.
static func store(enabled: bool, editor: Node = null) -> void:
	var config := ConfigFile.new()
	config.load(PATH)
	config.set_value(SECTION, KEY, enabled)
	# The opt-in key is dead; leaving it would look like a live setting to
	# anyone reading the file.
	if config.has_section_key(SECTION, LEGACY_KEY):
		config.erase_section_key(SECTION, LEGACY_KEY)
	if config.save(PATH) != OK and editor:
		editor.edit_message = "Fly navigation changed for this session; preference could not be saved."
