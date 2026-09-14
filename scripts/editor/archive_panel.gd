extends Node
## File operations for the authored construction, independent of live physics.
const Job := preload("res://scripts/editor/archive_job.gd")
var editor: Node3D
var message: Label
var save_button: Button
var open_button: Button
var save_dialog: FileDialog
var open_dialog: FileDialog
var job: RefCounted
var operation := ""
var queued_dialog := ""
var source_epoch := -1
var source_revision := -1
var source_testing := false
var selected_path := ""
var _input_was_enabled := true
var _unhandled_was_enabled := true
var _modal := false

func bind_editor(target: Node3D, column: VBoxContainer) -> void:
	editor = target
	var row := HBoxContainer.new()
	column.add_child(row)
	column.move_child(row, mini(5, column.get_child_count() - 1))
	save_button = Button.new()
	save_button.text = "Save build…"
	save_button.pressed.connect(func(): _queue_dialog("save"))
	row.add_child(save_button)
	open_button = Button.new()
	open_button.text = "Open build…"
	open_button.pressed.connect(func(): _queue_dialog("open"))
	row.add_child(open_button)
	message = Label.new()
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.custom_minimum_size.x = 300
	message.visible = false
	column.add_child(message)
	column.move_child(message, mini(6, column.get_child_count() - 1))
	save_dialog = _dialog(FileDialog.FILE_MODE_SAVE_FILE)
	save_dialog.title = "Save authored construction"
	save_dialog.current_file = "construction.p3d"
	save_dialog.file_selected.connect(save_to_path)
	open_dialog = _dialog(FileDialog.FILE_MODE_OPEN_FILE)
	open_dialog.title = "Open authored construction"
	open_dialog.file_selected.connect(open_path)

func _dialog(mode: FileDialog.FileMode) -> FileDialog:
	var dialog := FileDialog.new()
	dialog.file_mode = mode
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.p3d ; Powder 3D construction"])
	dialog.use_native_dialog = true
	dialog.canceled.connect(_end_modal)
	add_child(dialog)
	return dialog

func _queue_dialog(which: String) -> void:
	if operation != "" or _modal:
		return
	editor._end_stroke()
	queued_dialog = which
	message.text = "Finishing edit…" if editor.capturing else ""

func _begin_modal() -> void:
	_modal = true
	_input_was_enabled = editor.is_processing_input()
	_unhandled_was_enabled = editor.is_processing_unhandled_input()
	editor._reset_gesture()
	editor._stop_navigation()
	editor.set_process_input(false)
	editor.set_process_unhandled_input(false)

func _end_modal() -> void:
	if not _modal:
		return
	_modal = false
	editor.set_process_input(_input_was_enabled)
	editor.set_process_unhandled_input(_unhandled_was_enabled)

func save_to_path(path: String) -> void:
	_end_modal()
	if operation != "" or editor.capturing or editor.painting:
		message.text = "Finish the current edit before saving."
		return
	selected_path = path
	source_epoch = editor.sim.edit_epoch
	operation = "capture"
	message.text = "Saving build…"
	if editor.testing:
		_start_save(editor.build_snapshot)
	else:
		# Explicit save may capture the whole authored volume once. The GPU
		# request is ordered before any subsequent editing commands.
		editor.sim.request_readback(func(bytes: PackedByteArray):
			if not is_inside_tree():
				return
			if editor.sim.edit_epoch != source_epoch:
				operation = ""
				message.text = "The world changed before saving; save the current build again."
				return
			_start_save(bytes))

func _start_save(bytes: PackedByteArray) -> void:
	job = Job.new()
	var err: Error = job.save_authored(selected_path, bytes, VoxelCodec.GRID)
	if err != OK:
		operation = ""
		job = null
		message.text = "Could not start saving: " + error_string(err)
	else:
		operation = "save"

func open_path(path: String) -> void:
	_end_modal()
	if operation != "" or editor.capturing or editor.painting:
		message.text = "Finish the current edit before opening a build."
		return
	selected_path = path
	source_epoch = editor.sim.edit_epoch
	source_revision = editor.sim.edit_revision
	source_testing = editor.testing
	job = Job.new()
	var err: Error = job.load_authored(path, VoxelCodec.GRID)
	if err != OK:
		job = null
		message.text = "Could not start opening: " + error_string(err)
	else:
		operation = "open"
		message.text = "Opening build…"

func _process(_delta: float) -> void:
	if editor == null:
		return
	message.visible = not message.text.is_empty()
	var busy := operation != "" or queued_dialog != ""
	save_button.disabled = busy
	open_button.disabled = busy
	if queued_dialog != "" and not editor.capturing:
		var dialog := save_dialog if queued_dialog == "save" else open_dialog
		queued_dialog = ""
		message.text = ""
		_begin_modal()
		dialog.popup_centered_ratio(0.7)
	if job == null or not job.is_ready():
		return
	var result: Dictionary = job.take_result()
	job = null
	var completed_operation := operation
	operation = ""
	if not result.ok:
		message.text = result.error
		return
	if completed_operation == "save":
		message.text = "Saved build: " + selected_path.get_file()
		return
	if source_epoch != editor.sim.edit_epoch or source_revision != editor.sim.edit_revision or source_testing != editor.testing or editor.capturing or editor.painting:
		message.text = "The build changed while opening; open the file again to replace it."
		return
	if editor.replace_authored(result.bytes):
		message.text = "Opened build: " + selected_path.get_file()
	else:
		message.text = "Finish the current edit before replacing the build."
