extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/export_bundle_check.gd
## Validated, atomic four-file bundle plus overwrite/stale-validation gates.

const TARGET := "user://derelict_builder/export_bundle_check/airlock_2x2_bundle"

var _failed := false


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	_cleanup()
	var app = load("res://builder.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var fixture := _repo_root().path_join("crates/derelict_core/assets/golden_areas/airlock_2x2.json")
	var file := FileAccess.open(fixture, FileAccess.READ)
	if file == null:
		_fail("fixture missing")
		_finish()
		return
	var document: Dictionary = app.author.load_golden(file.get_as_text())
	_check_unknown_kit_rejected(app.author, document)
	app._session.start_new(document)
	if not app._apply_source_document(document):
		_fail("fixture hydration failed")
	await create_timer(0.15).timeout
	if not app._compile_ok or not app._session.validation_matches_current():
		_fail("representative source did not reach current validation: compile_ok=%s current=%s result=%s" % [
			app._compile_ok, app._session.validation_matches_current(), app._session.compile_result,
		])
	else:
		_check_bundle(app)
		_check_overwrite(app)
		await _check_stale_validation(app)
	app.get_tree().auto_accept_quit = true
	app.queue_free()
	await process_frame
	await process_frame
	_cleanup()
	_finish()


func _check_unknown_kit_rejected(author: Object, document: Dictionary) -> void:
	var unknown := document.duplicate(true)
	unknown["kit_id"] = "missing_runtime_kit"
	for operation in [
		["compile", author.compile(unknown)],
		["validate", author.validate(unknown)],
		["export", author.export_playable(unknown, "missing_runtime_kit")],
	]:
		var result: Dictionary = operation[1]
		var error := str(result.get("error", ""))
		if error.is_empty() or not error.contains("missing_runtime_kit"):
			_fail("%s silently accepted an unavailable kit: %s" % [operation[0], result])
	var offline_author = ClassDB.instantiate("DerelictAuthor")
	offline_author.set_content_root("")
	var offline_export: Dictionary = offline_author.export_playable(document, str(document.get("kit_id", "")))
	if not str(offline_export.get("error", "")).contains("configure a content root"):
		_fail("offline playable export did not require a resolved kit catalog: %s" % offline_export)


func _check_bundle(app: Node) -> void:
	var result: Dictionary = app._export_bundle(TARGET, false)
	if not bool(result.get("ok", false)):
		_fail("first bundle export failed: %s" % result.get("error", ""))
		return
	for name in ["source.golden_area.json", "layout.json", "gameplay_slice.json", "manifest.json"]:
		if not FileAccess.file_exists(TARGET.path_join(name)):
			_fail("bundle missing %s" % name)
	var manifest_file := FileAccess.open(TARGET.path_join("manifest.json"), FileAccess.READ)
	var manifest: Variant = JSON.parse_string(manifest_file.get_as_text())
	if not (manifest is Dictionary):
		_fail("manifest is not JSON")
		return
	if str(manifest.get("source_hash", "")) != app._session.current_source_hash():
		_fail("manifest source hash does not match the validated source")
	if manifest.get("validation_result", "") != "passed":
		_fail("manifest did not record validation success")
	if manifest.get("layout_schema", "") != "1.2.0" or manifest.get("gameplay_schema", "") != "1.1.0":
		_fail("manifest schema versions drifted")
	if str(manifest.get("kit_path", "")).is_empty():
		_fail("manifest omitted the resolved runtime kit path")


func _check_overwrite(app: Node) -> void:
	var blocked: Dictionary = app._export_bundle(TARGET, false)
	if str(blocked.get("code", "")) != "overwrite_required":
		_fail("existing bundle did not require an overwrite decision")
	var replaced: Dictionary = app._export_bundle(TARGET, true)
	if not bool(replaced.get("ok", false)) or not FileAccess.file_exists(TARGET.path_join("manifest.json")):
		_fail("atomic overwrite failed")


func _check_stale_validation(app: Node) -> void:
	var lattice = app.get_node("%OccupancyLattice")
	var room: Dictionary = lattice.get_rooms()[0].duplicate(true)
	var vars: Dictionary = app._ensure_vars(int(room["id"])).duplicate(true)
	vars["notes"] = "stale validation probe"
	app._on_room_edited(room, vars)
	var stale: Dictionary = app._export_bundle(TARGET, true)
	if str(stale.get("code", "")) != "StaleValidation":
		_fail("stale source was exported without revalidation")
	await create_timer(0.15).timeout
	if not app._session.validation_matches_current():
		_fail("source did not become exportable after debounce validation: compile_ok=%s result=%s" % [app._compile_ok, app._session.compile_result])


func _repo_root() -> String:
	return ProjectSettings.globalize_path("res://../..")


func _cleanup() -> void:
	var absolute := ProjectSettings.globalize_path(TARGET).simplify_path()
	var parent := absolute.get_base_dir()
	_remove_tree(absolute, parent)


func _remove_tree(path: String, allowed_parent: String) -> void:
	if path.get_base_dir() != allowed_parent:
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if dir.current_is_dir():
			_remove_tree(child, path)
		else:
			DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _finish() -> void:
	if _failed:
		print("EXPORT_BUNDLE: FAIL")
		quit(1)
	else:
		print("EXPORT_BUNDLE: PASS")
		quit(0)


func _fail(message: String) -> void:
	push_error("FAIL: %s" % message)
	_failed = true
