extends Node
## File operations for the authored construction, independent of live physics.
const Job := preload("res://scripts/editor/archive_job.gd")
var editor: Node3D
signal save_finished(ok: bool, token: int, generation: int)
signal save_canceled
var document_status: Label
var source_document := -1
var source_generation := -1
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
	save_button.pressed.connect(request_save)
	save_button.tooltip_text = "Cmd/Ctrl+S: Save · Cmd/Ctrl+Shift+S: Save As"
	row.add_child(save_button)
	open_button = Button.new()
	open_button.text = "Open build…"
	open_button.tooltip_text = "Cmd/Ctrl+O: Open a build"
	open_button.pressed.connect(func(): _queue_dialog("open"))
	row.add_child(open_button)
	message = Label.new()
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	message.custom_minimum_size.x = 300
	message.visible = false
	column.add_child(message)
	column.move_child(message, mini(6, column.get_child_count() - 1))
	document_status = Label.new()
	document_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	document_status.custom_minimum_size.x = 300
	column.add_child(document_status)
	column.move_child(document_status, mini(6, column.get_child_count() - 1))
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
	dialog.canceled.connect(func():
		_end_modal()
		if mode == FileDialog.FILE_MODE_SAVE_FILE:
			save_canceled.emit())
	add_child(dialog)
	return dialog

func request_save(save_as := false) -> void:
	_queue_dialog("save" if save_as or editor.document.path.is_empty() else "save_current")

## Queue one file action. A second request while one is queued, a dialog is
## open, an operation is running, or the unsaved-build guard is mid-flow is
## rejected with visible feedback; it never silently replaces the first.
func _queue_dialog(which: String, from_guard := false) -> void:
	var guard: Node = editor.get("document_guard")
	if operation != "":
		_reject("A file operation is still running; try again when it finishes.")
		return
	if _modal:
		_reject("Close the open dialog first.")
		return
	if queued_dialog != "":
		_reject("A file action is already waiting; finish it first.")
		return
	if not from_guard and is_instance_valid(guard) and not guard.state.is_empty():
		_reject("Answer the unsaved-build dialog first.")
		return
	editor.cancel_pending_paint()
	editor._end_stroke()
	queued_dialog = which
	message.text = "Finishing edit…" if editor.capturing else ""

func _reject(text: String) -> void:
	# A queued action already reporting its pending capture keeps that message.
	if queued_dialog != "" and editor.capturing and message.text == "Finishing edit…":
		return
	message.text = text

func _begin_modal() -> void:
	editor._release_shortcuts()
	editor.cancel_pending_paint()
	editor._end_stroke()
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
		save_finished.emit(false, -1, -1)
		return
	selected_path = path
	source_epoch = editor.sim.edit_epoch
	source_document = editor.document.current
	source_generation = editor.document.generation
	operation = "capture"
	message.text = "Saving build…"
	if editor.testing:
		var thermal: Variant = editor.get("build_thermal")
		_start_save(editor.build_snapshot, thermal if thermal is PackedByteArray else PackedByteArray())
	else:
		# Explicit save may capture the whole authored volume once, every
		# layer. The GPU requests are ordered before any subsequent editing commands.
		var captured := func(bytes: PackedByteArray, thermal: PackedByteArray):
			if not is_inside_tree():
				return
			if editor.sim.edit_epoch != source_epoch:
				operation = ""
				message.text = "The world changed before saving; save the current build again."
				save_finished.emit(false, source_document, source_generation)
				return
			_start_save(bytes, thermal)
		if editor.has_method("read_world"):
			editor.read_world(captured)
		else:
			editor.sim.request_readback(func(bytes: PackedByteArray): captured.call(bytes, PackedByteArray()))

func _start_save(bytes: PackedByteArray, thermal: PackedByteArray = PackedByteArray()) -> void:
	job = Job.new()
	var ambient: Variant = editor.sim.get("ambient_temp")
	var err: Error = job.save_authored(selected_path, bytes, VoxelCodec.GRID, thermal, ambient if ambient is float else 293.15)
	if err != OK:
		operation = ""
		job = null
		message.text = "Could not start saving: " + error_string(err)
		save_finished.emit(false, source_document, source_generation)
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
	save_button.text = "Save build…" if editor.document.path.is_empty() else "Save build"
	document_status.text = editor.document.label()
	document_status.tooltip_text = editor.document.path
	message.visible = not message.text.is_empty()
	var busy := operation != "" or queued_dialog != ""
	save_button.disabled = busy
	open_button.disabled = busy
	if queued_dialog != "" and not editor.capturing:
		var requested := queued_dialog
		queued_dialog = ""
		message.text = ""
		if requested == "save_current" and not editor.document.path.is_empty():
			save_to_path(editor.document.path)
		else:
			var dialog := open_dialog if requested == "open" else save_dialog
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
		if completed_operation == "save":
			save_finished.emit(false, source_document, source_generation)
		return
	if completed_operation == "save":
		var same_document: bool = editor.document.saved_capture(source_document, source_generation, selected_path)
		message.text = ("Saved build: " if same_document else "Saved previous build: ") + selected_path.get_file()
		if same_document and (editor.document.is_dirty() or editor.capturing or editor.painting):
			message.text += " · newer edits are unsaved"
		save_finished.emit(true, source_document, source_generation)
		return
	if source_epoch != editor.sim.edit_epoch or source_revision != editor.sim.edit_revision or source_testing != editor.testing or editor.capturing or editor.painting:
		message.text = "The build changed while opening; open the file again to replace it."
		return
	var apply := _apply_open.bind(result.bytes, result.get("thermal", PackedByteArray()), selected_path, source_epoch, source_revision, source_testing)
	if is_instance_valid(editor.document_guard):
		# Saving may overwrite the very file selected for Open. Re-read it after
		# Save instead of applying cached old bytes and falsely marking them saved.
		editor.document_guard.request("open", apply, open_path.bind(selected_path))
	else:
		apply.call()

func _apply_open(bytes: PackedByteArray, thermal: PackedByteArray, path: String, epoch: int, revision: int, testing: bool) -> void:
	if epoch != editor.sim.edit_epoch or revision != editor.sim.edit_revision or testing != editor.testing or editor.capturing or editor.painting:
		message.text = "The build changed while opening; open the file again to replace it."
		return
	if editor.replace_authored(bytes, thermal):
		editor.document.saved_capture(editor.document.current, editor.document.generation, path)
		message.text = "Opened build: " + path.get_file()
	else:
		message.text = "Finish the current edit before replacing the build."
