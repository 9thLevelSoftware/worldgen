extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/document_lifecycle_check.gd
## BuilderApp integration for session history, source saves, reopening, and guards.

const SOURCE_PATH := "user://derelict_builder/document_lifecycle_check.json"
const INVALID_SOURCE_PATH := "user://derelict_builder/document_lifecycle_invalid.json"
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

	# A Rust-readable source can still be outside the builder lattice bounds.
	# Reject it before the session adopts its path, history, or save target.
	var prior_path: String = app._session.source_path
	var prior_document: Dictionary = app._session.source_document.duplicate(true)
	var invalid_document: Dictionary = prior_document.duplicate(true)
	invalid_document["topology"]["rooms"][0]["cells"] = [[100, 0]]
	var invalid_text: String = app.author.save_golden(invalid_document)
	var invalid_file := FileAccess.open(INVALID_SOURCE_PATH, FileAccess.WRITE)
	invalid_file.store_string(invalid_text)
	invalid_file.close()
	app._open_document(INVALID_SOURCE_PATH)
	if app._session.source_path != prior_path or app._session.source_document != prior_document:
		_fail("rejected open changed the active session")
	if not lattice.has_occupied(Vector3i(0, 0, 0)) or lattice.has_occupied(Vector3i(100, 0, 0)):
		_fail("rejected open changed the visible lattice")
	app._save_document()
	if FileAccess.get_file_as_string(INVALID_SOURCE_PATH) != invalid_text:
		_fail("save after rejected open overwrote the rejected source")

	# When a role edit absorbs the authored goal room, its stable anchor follows
	# the retained room while the independent entry anchor stays intact.
	var anchored: Dictionary = app._empty_golden()
	anchored["scope"] = "derelict"
	anchored["entry_room"] = "entry_03"
	anchored["goal_room"] = "goal_02"
	anchored["topology"]["rooms"] = [
		{"id": 1, "stable_id": "retained_01", "role": "cargo", "deck": 0, "cells": [[0, 0]]},
		{"id": 2, "stable_id": "goal_02", "role": "bridge", "deck": 0, "cells": [[1, 0]]},
		{"id": 3, "stable_id": "entry_03", "role": "engineering", "deck": 0, "cells": [[3, 0]]},
	]
	app._session.start_new(anchored)
	if not app._apply_source_document(anchored):
		_fail("anchor coalescence fixture failed to hydrate")
	lattice.select_room_id(2)
	lattice.stamp_role("cargo")
	if app._entry_room != "entry_03" or app._goal_room != "retained_01":
		_fail("coalescence did not retarget entry/goal anchors: %s -> %s" % [app._entry_room, app._goal_room])

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

	# A vertical opening suppresses its ceiling. The authored ceiling override
	# must be removed as part of the topology command, and that cleanup must be
	# reversible with the same complete-document undo history.
	var vertical_doc: Dictionary = app._empty_golden()
	vertical_doc["topology"]["rooms"] = [
		{"id": 1, "stable_id": "lower_01", "role": "airlock", "deck": 0, "cells": [[0, 0]]},
		{"id": 2, "stable_id": "upper_01", "role": "airlock", "deck": 1, "cells": [[0, 0]]},
	]
	vertical_doc["module_overrides"]["ceilings"]["0|0|0"] = "ceiling_cap_1x1"
	app._session.start_new(vertical_doc)
	if not app._apply_source_document(vertical_doc):
		_fail("vertical override fixture failed to hydrate")
	app._lattice._commit_vertical(Vector3i(0, 0, 0), Vector3i(0, 0, 1))
	await create_timer(0.15).timeout
	if (app._module_overrides.get("ceilings", {}) as Dictionary).has("0|0|0"):
		_fail("vertical edit left stale ceiling override")
	if not app._compile_ok or not app._session.validation_matches_current():
		_fail("validation did not recover after stale override cleanup")
	if not app._session.can_undo():
		_fail("stale override cleanup was not recorded as undoable")
	app._undo_document()
	if not (app._module_overrides.get("ceilings", {}) as Dictionary).has("0|0|0"):
		_fail("undo did not restore the removed ceiling override")

	# Destructive actions are held behind the unsaved guard.
	var invoked := {"value": false}
	app._guard_unsaved(func() -> void: invoked["value"] = true)
	if invoked["value"] or not app._unsaved_dialog.visible:
		_fail("unsaved guard did not pause the destructive action")
	app._unsaved_dialog.hide()
	# A failed guarded Save must abandon the deferred destructive action. A
	# later successful Save As must never revive an old New/Open/Quit request.
	app._session.source_path = SOURCE_PATH.get_base_dir()
	app._on_unsaved_action(&"save")
	if invoked["value"] or app._continue_after_save or app._pending_destructive_action.is_valid():
		_fail("failed guarded save left a stale destructive continuation")
	app._guard_unsaved(func() -> void: invoked["value"] = true)
	if invoked["value"] or not app._unsaved_dialog.visible:
		_fail("unsaved guard did not recover after a failed guarded save")
	app._unsaved_dialog.hide()

	# Recovery is automatic after the debounce, not dependent on a clean close.
	await create_timer(0.9).timeout
	if not FileAccess.file_exists(RECOVERY_PATH):
		_fail("debounced recovery snapshot was not written")
	# ConfirmationDialog hides before emitting confirmed on Godot 4.7. A
	# builder-invalid recovery must reopen the dialog so retry/discard remains
	# available without restarting the application.
	var invalid_recovery: Dictionary = app._session.source_document.duplicate(true)
	invalid_recovery["topology"]["rooms"][0]["cells"] = [[100, 0]]
	var recovery_file := FileAccess.open(RECOVERY_PATH, FileAccess.WRITE)
	recovery_file.store_string(app.author.save_golden(invalid_recovery))
	recovery_file.close()
	app._recovery_dialog.hide()
	app._restore_recovery()
	await process_frame
	await process_frame
	if not app._recovery_dialog.visible:
		_fail("failed recovery did not keep retry/discard available")
	app._recovery_dialog.hide()
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
	for path in [SOURCE_PATH, SOURCE_PATH + ".bak", INVALID_SOURCE_PATH, INVALID_SOURCE_PATH + ".bak", RECOVERY_PATH, RECOVERY_PATH + ".bak"]:
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
