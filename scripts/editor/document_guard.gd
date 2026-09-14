extends Node
## One destructive user intent, authorized against one authored checkpoint.
## Saving remains explicit; newer edits never inherit an earlier discard choice.
var editor: Node3D
var archive: Node
var dialog: ConfirmationDialog
var discard_button: Button
var state := ""
var action := ""
var continuation: Callable
var saved_continuation: Callable
var source_epoch := -1
var prompt_token := -1
var _previous_quit := true
var _owns_quit := false
signal action_completed(kind: String)

func bind_editor(target: Node3D) -> void:
	editor = target
	archive = editor.archive_panel
	dialog = ConfirmationDialog.new()
	dialog.title = "Unsaved build"
	dialog.dialog_autowrap = true
	dialog.ok_button_text = "Save build"
	dialog.cancel_button_text = "Cancel"
	dialog.exclusive = true
	discard_button = dialog.add_button("Discard", false, "discard")
	dialog.confirmed.connect(_save_first)
	dialog.custom_action.connect(func(which):
		if which == "discard":
			_discard())
	dialog.canceled.connect(cancel)
	add_child(dialog)
	archive.save_finished.connect(_saved)
	archive.save_canceled.connect(cancel)
	_previous_quit = get_tree().auto_accept_quit
	get_tree().auto_accept_quit = false
	get_tree().root.close_requested.connect(request_close)
	_owns_quit = true

func _exit_tree() -> void:
	if _owns_quit:
		get_tree().auto_accept_quit = _previous_quit
	_owns_quit = false

func request_close() -> void:
	request("close", func(): get_tree().quit())

func request(kind: String, callback: Callable, after_save: Callable = Callable()) -> void:
	if not state.is_empty():
		return
	if archive._modal or not archive.queued_dialog.is_empty():
		archive.message.text = "Close the file dialog before " + ("quitting." if kind == "close" else "replacing the build.")
		return
	editor.cancel_pending_paint()
	editor._end_stroke()
	action = kind
	continuation = callback
	saved_continuation = after_save
	source_epoch = editor.sim.edit_epoch
	state = "waiting"
	# Own scene input while a final history capture/file operation finishes.
	archive._begin_modal()
	_poll()

func _process(_delta: float) -> void:
	if state == "waiting":
		_poll()

func _poll() -> void:
	if editor.sim.edit_epoch != source_epoch:
		_cancel_changed()
		return
	if editor.capturing or archive.operation != "":
		return
	if not editor.document.is_dirty():
		_execute()
		return
	prompt_token = editor.document.current
	var purpose: String = {"reset": "resetting the container", "empty": "starting an empty build", "open": "opening another build", "close": "closing"}.get(action, "continuing")
	dialog.dialog_text = "Save changes to %s before %s?" % ["this untitled build" if editor.document.path.is_empty() else editor.document.path.get_file(), purpose]
	state = "prompt"
	dialog.popup_centered(Vector2i(430, 150))
	# Cancel is the safe default; Space/Enter must not implicitly discard.
	dialog.get_cancel_button().grab_focus()

func cancel() -> void:
	if state.is_empty():
		return
	dialog.hide()
	archive._end_modal()
	state = ""
	action = ""
	continuation = Callable()
	saved_continuation = Callable()

func _cancel_changed() -> void:
	cancel()
	archive.message.text = "The build changed; the requested action was canceled."

func _discard() -> void:
	if state != "prompt":
		return
	if editor.capturing or editor.painting or editor.pending_authored or editor.sim.edit_epoch != source_epoch or editor.document.current != prompt_token:
		_cancel_changed()
		return
	_execute()

func _save_first() -> void:
	if state != "prompt":
		return
	if editor.capturing or editor.painting or editor.pending_authored or editor.sim.edit_epoch != source_epoch or editor.document.current != prompt_token:
		_cancel_changed()
		return
	dialog.hide()
	archive._end_modal()
	state = "saving"
	if editor.document.path.is_empty():
		archive._queue_dialog("save")
	else:
		archive.save_to_path(editor.document.path)

func _saved(ok: bool, token: int, generation: int) -> void:
	if state != "saving":
		return
	if not ok:
		cancel()
		return
	# A successful old snapshot is not permission to destroy newer work, even
	# when its asynchronous stroke has not assigned a document ID yet.
	if editor.capturing or editor.painting or editor.pending_authored or editor.sim.edit_epoch != source_epoch or editor.document.generation != generation or editor.document.current != token or editor.document.is_dirty():
		_cancel_changed()
		return
	_execute(true)

func _execute(saved_first := false) -> void:
	var callback := saved_continuation if saved_first and saved_continuation.is_valid() else continuation
	var kind := action
	cancel()
	action_completed.emit(kind)
	if callback.is_valid():
		callback.call()
