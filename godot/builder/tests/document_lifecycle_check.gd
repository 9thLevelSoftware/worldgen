extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/document_lifecycle_check.gd
## BuilderApp integration for session history, source saves, reopening, and guards.

const SOURCE_PATH := "user://derelict_builder/document_lifecycle_check.json"
const RECOVERY_PATH := "user://derelict_builder/recovery/active.json"

var _failed := false


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	_cleanup()
	var scene = load("res://builder.tscn")
	var app = scene.instantiate()
	root.add_child(app)
	await process_frame

	_check_actions_enabled(app)
	var lattice = app.get_node("%OccupancyLattice")
	lattice.active_role = "airlock"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("representative room paint failed")
	await process_frame
	if not app._session.has_unsaved_changes():
		_fail("edit did not mark the source dirty")
	if app.get_node("%UndoBtn").disabled:
		_fail("Undo stayed disabled after an edit")

	app._save_document_as(SOURCE_PATH)
	if app._session.has_unsaved_changes() or not FileAccess.file_exists(SOURCE_PATH):
		_fail("Save As did not persist and clear dirty state")

	# A complete-document snapshot must restore split/dependent state, not only
	# a single field. Here the first undo returns to empty, redo rehydrates room 1.
	app._undo_document()
	if not lattice.get_rooms().is_empty():
		_fail("undo did not hydrate the prior complete document")
	app._redo_document()
	if lattice.get_rooms().size() != 1 or not lattice.has_occupied(Vector3i(0, 0, 0)):
		_fail("redo did not rehydrate the edited document")

	# Opening the saved canonical source restores the same authored meaning.
	app._new_document()
	app._open_document(SOURCE_PATH)
	if lattice.get_rooms().size() != 1 or str(lattice.get_rooms()[0].get("stable_id", "")) != "airlock_01":
		_fail("open did not fully hydrate the saved source")

	# Rebuilding an opened derelict must not silently downgrade its validation
	# scope merely because it contains more than one room.
	lattice.active_role = "cargo"
	lattice.paint_cell(Vector3i(2, 0, 0))
	app._scope = "derelict"
	var authored_rooms: Array = lattice.get_rooms()
	app._entry_room = str(authored_rooms[0].get("stable_id", ""))
	app._goal_room = str(authored_rooms[1].get("stable_id", ""))
	var rebuilt: Dictionary = app._golden_from_lattice()
	if str(rebuilt.get("scope", "")) != "derelict" \
			or str(rebuilt.get("entry_room", "")) != app._entry_room \
			or str(rebuilt.get("goal_room", "")) != app._goal_room:
		_fail("source reconstruction downgraded derelict scope or anchors")

	# Destructive actions are held behind the unsaved guard.
	var invoked := {"value": false}
	app._guard_unsaved(func() -> void: invoked["value"] = true)
	if invoked["value"] or not app._unsaved_dialog.visible:
		_fail("unsaved guard did not pause the destructive action")
	app._unsaved_dialog.hide()

	# Recovery is automatic after the debounce, not dependent on a clean close.
	await create_timer(0.9).timeout
	if not FileAccess.file_exists(RECOVERY_PATH):
		_fail("debounced recovery snapshot was not written")
	app._discard_and_continue_destructive_action()
	if not bool(invoked["value"]) or FileAccess.file_exists(RECOVERY_PATH):
		_fail("discard did not continue the action and remove recovery data")

	app.get_tree().auto_accept_quit = true
	app.queue_free()
	await process_frame
	await process_frame
	_cleanup()
	_finish()


func _check_actions_enabled(app: Node) -> void:
	for node_name in ["NewBtn", "OpenBtn", "SaveBtn", "SaveAsBtn"]:
		var button: Button = app.get_node("%%%s" % node_name)
		if button.disabled:
			_fail("%s is still disabled" % node_name)


func _cleanup() -> void:
	for path in [SOURCE_PATH, SOURCE_PATH + ".bak", RECOVERY_PATH, RECOVERY_PATH + ".bak"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _finish() -> void:
	if _failed:
		print("DOCUMENT_LIFECYCLE: FAIL")
		quit(1)
	else:
		print("DOCUMENT_LIFECYCLE: PASS")
		quit(0)


func _fail(message: String) -> void:
	push_error("FAIL: %s" % message)
	_failed = true
