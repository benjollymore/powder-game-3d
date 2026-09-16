extends RefCounted
## Whether WASD fly navigation is on, remembered beside the picture preference
## in the same user config file (scripts/editor/display_preferences.gd).
const PATH := "user://editor_preferences.cfg"


static func load_enabled() -> bool:
	var config := ConfigFile.new()
	config.load(PATH)
	var saved: Variant = config.get_value("camera", "fly", false)
	return saved if saved is bool else false


## A preference that cannot be written still applies to this session; the
## editor says so rather than silently reverting the toggle.
static func store(enabled: bool, editor: Node = null) -> void:
	var config := ConfigFile.new()
	config.load(PATH)
	config.set_value("camera", "fly", enabled)
	if config.save(PATH) != OK and editor:
		editor.edit_message = "Fly navigation changed for this session; preference could not be saved."
