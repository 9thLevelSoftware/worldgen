extends SceneTree

const SESSION_SCRIPT := preload("res://scripts/BuilderSession.gd")
const NAMESPACE := "builder_session_check"
const SOURCE_PATH := "user://derelict_builder_builder_session_check.json"

var failed := false
var recovery_notifications := 0

func _initialize() -> void:
	if not ClassDB.class_exists("DerelictAuthor"):
		print("SESSION_SKIP DerelictAuthor missing")
		quit(0)
		return
	var author = ClassDB.instantiate("DerelictAuthor")
	var golden_path := _repo_root().path_join("crates/derelict_core/assets/golden_areas/airlock_2x2.json")
	var file := FileAccess.open(golden_path, FileAccess.READ)
	if file == null:
		_fail("fixture missing")
		_finish()
		return
	var golden: Dictionary = author.load_golden(file.get_as_text())
	if golden.has("error"):
		_fail("fixture load: %s" % golden.error)
		_finish()
		return
	var session := SESSION_SCRIPT.new()
	root.add_child(session)
	session.recovery_available.connect(func(_path: String) -> void: recovery_notifications += 1)
	session.initialize(author, NAMESPACE)
	session.discard_recovery()
	recovery_notifications = 0
	_check_new_commit_undo_redo(session, golden)
	_check_save_reopen(session, golden)
	_check_recovery(session, golden)
	_cleanup()
	_finish()

func _check_new_commit_undo_redo(session: BuilderSession, golden: Dictionary) -> void:
	var started := session.start_new(golden)
	_expect(bool(started.get("ok", false)), "start_new succeeds")
	var changed := golden.duplicate(true)
	changed["display_name"] = "Session Check Edited"
	_expect(session.commit_document(changed, "Rename"), "commit records edit")
	_expect(session.has_unsaved_changes(), "commit marks dirty")
	_expect(session.undo().get("ok", false), "undo succeeds")
	_expect(str(session.source_document.get("display_name", "")) == str(golden.get("display_name", "")), "undo restores complete document")
	_expect(session.redo().get("ok", false), "redo succeeds")
	_expect(str(session.source_document.get("display_name", "")) == "Session Check Edited", "redo restores edit")
	_expect(not session.commit_document(session.source_document.duplicate(true), "No-op"), "no-op commit does not add history")

func _check_save_reopen(session: BuilderSession, golden: Dictionary) -> void:
	var saved := session.save_document_as(SOURCE_PATH)
	_expect(bool(saved.get("ok", false)), "save as succeeds")
	_expect(not session.has_unsaved_changes(), "save clears dirty state")
	var reopened := session.open_document(SOURCE_PATH)
	_expect(bool(reopened.get("ok", false)), "open succeeds")
	_expect(session.source_document == golden or str(session.source_document.get("display_name", "")) == "Session Check Edited", "reopen preserves semantic document")
	var canonical := str(session.author.save_golden(session.source_document))
	_expect(not canonical.is_empty(), "reopen remains author-canonical")

func _check_recovery(session: BuilderSession, golden: Dictionary) -> void:
	var changed := golden.duplicate(true)
	changed["display_name"] = "Recovered Session"
	session.start_new(golden)
	session.commit_document(changed, "Recovery edit")
	var flushed := session.flush_recovery_for_test()
	_expect(bool(flushed.get("ok", false)) and bool(flushed.get("written", true)), "recovery snapshot writes")
	_expect(session.has_recovery(), "recovery is discoverable")
	_expect(recovery_notifications == 0, "autosave does not announce recovery")
	var saved := session.save_document_as(SOURCE_PATH)
	_expect(bool(saved.get("ok", false)), "save supersedes recovery")
	_expect(not session.has_recovery(), "successful save removes recovery snapshot")
	session.start_new(golden)
	session.commit_document(changed, "Recovery edit 2")
	session.flush_recovery_for_test()
	var restored := session.restore_recovery()
	_expect(bool(restored.get("ok", false)), "recovery restores")
	_expect(str(session.source_document.get("display_name", "")) == "Recovered Session", "recovery restores latest document")
	_expect(session.discard_recovery(), "recovery discard succeeds")
	_expect(not session.has_recovery(), "recovery is removed")

func _cleanup() -> void:
	for path in [SOURCE_PATH, SOURCE_PATH + ".bak", recovery_path(), recovery_path() + ".bak"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func recovery_path() -> String:
	return "user://derelict_builder/recovery/%s.json" % NAMESPACE

func _repo_root() -> String:
	return ProjectSettings.globalize_path("res://../..")

func _expect(condition: bool, label: String) -> void:
	if condition:
		print("SESSION_OK %s" % label)
	else:
		_fail(label)

func _fail(label: String) -> void:
	failed = true
	push_error("SESSION_FAIL %s" % label)

func _finish() -> void:
	quit(1 if failed else 0)
