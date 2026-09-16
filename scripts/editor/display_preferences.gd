extends RefCounted
## Editor-only presentation preference. It never changes simulation resolution.
const PreferenceStore := preload("res://scripts/editor/preference_store.gd")

static func apply(viewport: Viewport, sharper: bool) -> void:
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = 1.0 if sharper else 0.75
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA

static func mount(editor: Node3D, parent: Container) -> void:
	var config := ConfigFile.new()
	config.load(PreferenceStore.path())
	var saved: Variant = config.get_value("display", "sharper", true)
	var sharper: bool = saved if saved is bool else true
	# Measurement scripts can explicitly hold a chosen viewport configuration.
	var measured_override := false
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("quality=") and argument != "quality=editor":
			measured_override = true
	if not measured_override:
		apply(editor.get_viewport(), sharper)
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Picture  "
	row.add_child(label)
	var choice := OptionButton.new()
	choice.name = "PictureQuality"
	choice.add_item("Sharper")
	choice.add_item("Faster")
	choice.select(0 if editor.get_viewport().scaling_3d_scale >= 1.0 else 1)
	choice.tooltip_text = "Sharper: clearer edges at full resolution. Faster: lower picture resolution for more headroom. The world and brush stay the same size."
	choice.item_selected.connect(func(index: int):
		editor._end_stroke()
		apply(editor.get_viewport(), index == 0)
		config.set_value("display", "sharper", index == 0)
		if config.save(PreferenceStore.path()) != OK:
			editor.edit_message = "Picture changed for this session; preference could not be saved.")
	row.add_child(choice)
	parent.add_child(row)
	parent.move_child(row, 0)
