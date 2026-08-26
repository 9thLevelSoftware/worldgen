class_name ContentRoot
extends Node
## Resolves The Synaptic Sea content root for palettes and (later) GLB preview.
## Never writes under that root; only `user://builder_settings.json`.

const SETTINGS_PATH := "user://builder_settings.json"
const DEFAULT_WIN := "D:/the-synaptic-sea"
const SIBLING_NAME := "the-synaptic-sea"


func resolve() -> Dictionary:
	var env := OS.get_environment("SYNAPTIC_SEA_ROOT").strip_edges()
	if not env.is_empty() and _is_dir(env):
		return _ok(env, "env")

	var from_settings := _read_settings_path()
	if not from_settings.is_empty() and _is_dir(from_settings):
		return _ok(from_settings, "settings")

	for candidate in _sibling_candidates():
		if _is_dir(candidate):
			_persist(candidate)
			return _ok(candidate, "sibling")

	return {"path": "", "offline": true, "source": "offline"}


func persist(path: String) -> void:
	_persist(path)


func _ok(path: String, source: String) -> Dictionary:
	return {"path": path.simplify_path(), "offline": false, "source": source}


func _is_dir(path: String) -> bool:
	if path.is_empty():
		return false
	return DirAccess.open(path) != null


func _read_settings_path() -> String:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return ""
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
	if f == null:
		return ""
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return ""
	return str((parsed as Dictionary).get("synaptic_sea_root", "")).strip_edges()


func _persist(path: String) -> void:
	if path.is_empty():
		return
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"synaptic_sea_root": path}, "\t"))


func _sibling_candidates() -> Array[String]:
	var out: Array[String] = [DEFAULT_WIN]
	var dir := ProjectSettings.globalize_path("res://").simplify_path()
	var hops := 0
	while hops < 6:
		out.append(dir.path_join(SIBLING_NAME))
		out.append(dir.path_join("..").path_join(SIBLING_NAME).simplify_path())
		var parent := dir.get_base_dir()
		if parent == dir or parent.is_empty():
			break
		dir = parent
		hops += 1
	var cwd := OS.get_executable_path().get_base_dir()
	if not cwd.is_empty():
		out.append(cwd.path_join("..").path_join(SIBLING_NAME).simplify_path())
	return out
