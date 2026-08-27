class_name BuilderSession
extends Node

## Document/session boundary for the standalone builder.
## GoldenArea dictionaries are always normalized through DerelictAuthor so the
## editor never compares an ad-hoc JSON representation with the saved source.

signal document_changed(document)
signal path_changed(path)
signal dirty_changed(dirty)
signal history_changed(can_undo, can_redo)
signal recovery_available(path)
signal session_error(message)

const ROOT := "user://derelict_builder"
const RECOVERY_ROOT := ROOT + "/recovery"
const RECENT_FILE := ROOT + "/recent.cfg"
const RECOVERY_DEBOUNCE_S := 0.75

var author: Object
var source_path: String = ""
var source_document: Dictionary = {}
var selection: Dictionary = {}
var active_stage: String = "geometry"
var active_tool: String = "select"
var compile_result: Dictionary = {}
var recovery_namespace: String = "default"

var _saved_canonical: String = ""
var _validated_source_hash: String = ""
var _undo_stack: Array[String] = []
var _redo_stack: Array[String] = []
var _recovery_pending := false
var _recovery_timer: Timer


func _ready() -> void:
	_ensure_recovery_timer()

func initialize(author_instance: Object, namespace_id: String = "default") -> void:
	author = author_instance
	recovery_namespace = _safe_name(namespace_id)
	_ensure_dirs()
	_ensure_recovery_timer()
	if has_recovery():
		recovery_available.emit(recovery_path())

func start_new(document: Dictionary = {}) -> Dictionary:
	var canonical := _canonicalize(document)
	if canonical.is_empty() and not document.is_empty():
		return _error("Cannot create document: %s" % _last_error)
	source_path = ""
	source_document = canonical
	_saved_canonical = _serialize(canonical)
	_undo_stack.clear()
	_redo_stack.clear()
	compile_result.clear()
	_validated_source_hash = ""
	_recovery_pending = false
	_stop_recovery_timer()
	path_changed.emit(source_path)
	document_changed.emit(source_document)
	dirty_changed.emit(false)
	history_changed.emit(false, false)
	return {"ok": true, "document": source_document}

func open_document(path: String, before_commit: Callable = Callable()) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return _error("Source document not found: %s" % path)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _error("Unable to open source document: %s" % path)
	var loaded := _canonicalize_text(file.get_as_text())
	if loaded.is_empty() and not _last_error.is_empty():
		return _error(_last_error)
	# Let the workspace hydrate the candidate before this session adopts its
	# path or clears history. Rejected builder-specific geometry must leave the
	# currently open source completely unchanged.
	if before_commit.is_valid() and not bool(before_commit.call(loaded.duplicate(true))):
		return {"ok": false, "error": "The source could not be hydrated by this builder."}
	source_path = path
	source_document = loaded
	_saved_canonical = _serialize(loaded)
	_undo_stack.clear()
	_redo_stack.clear()
	compile_result.clear()
	_validated_source_hash = ""
	_recovery_pending = false
	_stop_recovery_timer()
	_remember(path)
	path_changed.emit(source_path)
	document_changed.emit(source_document)
	dirty_changed.emit(false)
	history_changed.emit(false, false)
	return {"ok": true, "document": source_document, "path": source_path}

func save_document() -> Dictionary:
	if source_path.is_empty():
		return _error("No source path; use Save As")
	return _save_to(source_path)

func save_document_as(path: String) -> Dictionary:
	if path.is_empty():
		return _error("Save path is empty")
	var result := _save_to(path)
	if bool(result.get("ok", false)):
		source_path = path
		_remember(path)
		path_changed.emit(source_path)
	return result

func commit_document(document: Dictionary, label: String = "Edit") -> bool:
	var canonical := _canonicalize(document)
	if canonical.is_empty() and not document.is_empty():
		session_error.emit("Cannot commit document: %s" % _last_error)
		return false
	var before := _serialize(source_document)
	var after := _serialize(canonical)
	if before == after:
		return false
	_undo_stack.append(before)
	_redo_stack.clear()
	source_document = canonical
	_update_recovery_state()
	document_changed.emit(source_document)
	dirty_changed.emit(has_unsaved_changes())
	history_changed.emit(can_undo(), can_redo())
	return true

func undo() -> Dictionary:
	if _undo_stack.is_empty():
		return _error("Nothing to undo")
	var current := _serialize(source_document)
	var target := _canonicalize_text(_undo_stack.pop_back())
	if target.is_empty() and not _last_error.is_empty():
		return _error(_last_error)
	_redo_stack.append(current)
	source_document = target
	_update_recovery_state()
	document_changed.emit(source_document)
	dirty_changed.emit(has_unsaved_changes())
	history_changed.emit(can_undo(), can_redo())
	return {"ok": true, "document": source_document}

func redo() -> Dictionary:
	if _redo_stack.is_empty():
		return _error("Nothing to redo")
	var current := _serialize(source_document)
	var target := _canonicalize_text(_redo_stack.pop_back())
	if target.is_empty() and not _last_error.is_empty():
		return _error(_last_error)
	_undo_stack.append(current)
	source_document = target
	_update_recovery_state()
	document_changed.emit(source_document)
	dirty_changed.emit(has_unsaved_changes())
	history_changed.emit(can_undo(), can_redo())
	return {"ok": true, "document": source_document}

func can_undo() -> bool:
	return not _undo_stack.is_empty()

func can_redo() -> bool:
	return not _redo_stack.is_empty()

func set_compile_result(result: Dictionary, document: Dictionary = {}) -> void:
	compile_result = result.duplicate(true)
	var checked := document if not document.is_empty() else source_document
	var has_error := not str(result.get("error", "")).is_empty()
	var issues: Variant = result.get("issues", [])
	var stale: Variant = result.get("stale_overrides", [])
	var clean := not has_error and issues is Array and (issues as Array).is_empty()
	clean = clean and stale is Array and (stale as Array).is_empty()
	_validated_source_hash = _hash_canonical(_serialize(checked)) if clean else ""

func validation_matches_current() -> bool:
	return not _validated_source_hash.is_empty() and _validated_source_hash == current_source_hash()

func current_source_hash() -> String:
	return _hash_canonical(_serialize(source_document))

func has_unsaved_changes() -> bool:
	return _serialize(source_document) != _saved_canonical

func recent_documents() -> PackedStringArray:
	var config := ConfigFile.new()
	if config.load(RECENT_FILE) != OK:
		return PackedStringArray()
	var values: PackedStringArray = config.get_value("documents", "paths", PackedStringArray())
	return values

func recovery_path() -> String:
	return "%s/%s.json" % [RECOVERY_ROOT, recovery_namespace]

func has_recovery() -> bool:
	return FileAccess.file_exists(recovery_path())

func restore_recovery(before_commit: Callable = Callable()) -> Dictionary:
	if not has_recovery():
		return _error("No recovery snapshot available")
	var file := FileAccess.open(recovery_path(), FileAccess.READ)
	if file == null:
		return _error("Unable to read recovery snapshot")
	var loaded := _canonicalize_text(file.get_as_text())
	if loaded.is_empty() and not _last_error.is_empty():
		return _error(_last_error)
	# Hydrate the candidate before changing session state. A builder-specific
	# rejection must leave the active document, history, and recovery file
	# available for another attempt.
	if before_commit.is_valid() and not bool(before_commit.call(loaded.duplicate(true))):
		return _error("The recovery snapshot could not be hydrated by this builder.")
	_undo_stack.clear()
	_redo_stack.clear()
	source_document = loaded
	_recovery_pending = false
	_stop_recovery_timer()
	document_changed.emit(source_document)
	dirty_changed.emit(has_unsaved_changes())
	history_changed.emit(false, false)
	return {"ok": true, "document": source_document, "path": recovery_path()}

func discard_recovery() -> bool:
	var had_recovery := has_recovery()
	_recovery_pending = false
	_stop_recovery_timer()
	if not had_recovery:
		return false
	var err := DirAccess.remove_absolute(ProjectSettings.globalize_path(recovery_path()))
	if err != OK:
		session_error.emit("Unable to discard recovery snapshot")
		return false
	return true

func flush_recovery_for_test() -> Dictionary:
	_stop_recovery_timer()
	if not _recovery_pending:
		return {"ok": true, "written": false, "path": recovery_path()}
	_ensure_dirs()
	var result := _atomic_write(recovery_path(), _serialize(source_document))
	if bool(result.get("ok", false)):
		_recovery_pending = false
		result["written"] = true
	return result

func _canonicalize(document: Dictionary) -> Dictionary:
	if author == null or not is_instance_valid(author):
		_last_error = "DerelictAuthor is unavailable"
		return {}
	var text := str(author.save_golden(document))
	if text.is_empty():
		_last_error = "DerelictAuthor rejected the document"
		return {}
	return _canonicalize_text(text)

func _canonicalize_text(text: String) -> Dictionary:
	if author == null or not is_instance_valid(author):
		_last_error = "DerelictAuthor is unavailable"
		return {}
	var loaded: Variant = author.load_golden(text)
	if not loaded is Dictionary or (loaded as Dictionary).has("error"):
		_last_error = str((loaded as Dictionary).get("error", "Invalid GoldenArea")) if loaded is Dictionary else "Invalid GoldenArea"
		return {}
	return (loaded as Dictionary).duplicate(true)

func _serialize(document: Dictionary) -> String:
	if author == null or not is_instance_valid(author):
		return ""
	var first := str(author.save_golden(document))
	if first.is_empty():
		return ""
	var loaded: Variant = author.load_golden(first)
	if not (loaded is Dictionary) or (loaded as Dictionary).has("error"):
		return ""
	return str(author.save_golden(loaded as Dictionary))

var _last_error := ""

func _save_to(path: String) -> Dictionary:
	var content := _serialize(source_document)
	if content.is_empty():
		return _error("Cannot serialize source document")
	var result := _atomic_write(path, content)
	if bool(result.get("ok", false)):
		_saved_canonical = content
		_recovery_pending = false
		_stop_recovery_timer()
		# A successful source save supersedes any crash-recovery snapshot.
		if has_recovery():
			discard_recovery()
		_remember(path)
		dirty_changed.emit(false)
	return result

func _atomic_write(path: String, content: String) -> Dictionary:
	var absolute := ProjectSettings.globalize_path(path)
	var parent := absolute.get_base_dir()
	DirAccess.make_dir_recursive_absolute(parent)
	var temp := absolute + ".tmp.%s" % str(Time.get_ticks_usec())
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return _error("Unable to write temporary source: %s" % path)
	file.store_string(content)
	file.flush()
	file.close()
	var backup := absolute + ".bak"
	var had_old := FileAccess.file_exists(absolute)
	if had_old:
		DirAccess.remove_absolute(backup)
		if DirAccess.rename_absolute(absolute, backup) != OK:
			DirAccess.remove_absolute(temp)
			return _error("Unable to stage existing source: %s" % path)
	if DirAccess.rename_absolute(temp, absolute) != OK:
		if had_old:
			DirAccess.rename_absolute(backup, absolute)
		DirAccess.remove_absolute(temp)
		return _error("Unable to finalize source: %s" % path)
	if had_old:
		DirAccess.remove_absolute(backup)
	return {"ok": true, "path": path, "bytes": content.to_utf8_buffer().size()}

func _remember(path: String) -> void:
	if path.is_empty():
		return
	_ensure_dirs()
	var paths := recent_documents()
	var next := PackedStringArray([path])
	for old in paths:
		if old != path and next.size() < 12:
			next.append(old)
	var config := ConfigFile.new()
	config.set_value("documents", "paths", next)
	config.save(RECENT_FILE)

func _ensure_dirs() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RECOVERY_ROOT))


func _ensure_recovery_timer() -> void:
	if _recovery_timer != null:
		return
	_recovery_timer = Timer.new()
	_recovery_timer.one_shot = true
	_recovery_timer.wait_time = RECOVERY_DEBOUNCE_S
	_recovery_timer.timeout.connect(_flush_recovery_debounced)
	add_child(_recovery_timer)


func _schedule_recovery() -> void:
	_recovery_pending = true
	_ensure_recovery_timer()
	if _recovery_timer.is_inside_tree():
		_recovery_timer.start(RECOVERY_DEBOUNCE_S)
	else:
		call_deferred("_start_recovery_timer")


func _update_recovery_state() -> void:
	if has_unsaved_changes():
		_schedule_recovery()
		return
	# Returning to the saved canonical document is clean. Cancel any pending
	# debounce and remove a snapshot from an earlier dirty state so the next
	# launch cannot offer already-saved work for recovery.
	_recovery_pending = false
	_stop_recovery_timer()
	if has_recovery():
		discard_recovery()


func _start_recovery_timer() -> void:
	if _recovery_pending and _recovery_timer != null and _recovery_timer.is_inside_tree():
		_recovery_timer.start(RECOVERY_DEBOUNCE_S)


func _stop_recovery_timer() -> void:
	if _recovery_timer != null:
		_recovery_timer.stop()


func _flush_recovery_debounced() -> void:
	var result := flush_recovery_for_test()
	if not bool(result.get("ok", false)):
		session_error.emit(str(result.get("error", "Unable to write recovery snapshot")))

func _safe_name(value: String) -> String:
	var out := value.strip_edges().replace("/", "_").replace("\\", "_")
	return out if not out.is_empty() else "default"


func _hash_canonical(content: String) -> String:
	if content.is_empty():
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(content.to_utf8_buffer())
	return context.finish().hex_encode()

func _error(message: String) -> Dictionary:
	_last_error = message
	session_error.emit(message)
	return {"ok": false, "error": message}
