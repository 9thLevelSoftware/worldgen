extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/structural_preview_check.gd
## Confirms ship_structural_v0 GLBs load and airlock_2x2 previews from kit files.

const REQUIRED := ["floor_1x1", "wall_straight_1x1", "doorway_frame_open_1x1"]


func _initialize() -> void:
	var failed := false
	var root_info: Dictionary = _resolve_content()
	var content_root := str(root_info.get("path", ""))
	print("CONTENT_ROOT source=%s path=%s offline=%s" % [
		root_info.get("source", ""), content_root, root_info.get("offline", true)
	])
	if content_root.is_empty():
		push_error("FAIL: D:\\the-synaptic-sea (or SYNAPTIC_SEA_ROOT) not found")
		quit(1)
		return

	for id in REQUIRED:
		var path := content_root.path_join("assets/imported/structural/ship_structural_v0/%s/%s.glb" % [id, id])
		path = path.simplify_path()
		if not FileAccess.file_exists(path):
			push_error("FAIL: missing GLB %s" % path)
			failed = true
			continue
		print("GLB_OK %s" % path)
		if not _gltf_loads(path):
			push_error("FAIL: GLTFDocument could not load %s" % path)
			failed = true
		else:
			print("GLTF_OK %s" % id)

	if not ClassDB.class_exists("DerelictAuthor"):
		push_error("FAIL: DerelictAuthor missing (copy derelict_godot.dll into addons/derelict/bin/win64)")
		quit(1)
		return

	var author = ClassDB.instantiate("DerelictAuthor")
	var set_root: Dictionary = author.set_content_root(content_root)
	print("SET_CONTENT_ROOT ok=%s errors=%s" % [set_root.get("ok", false), set_root.get("errors", [])])

	var golden_path := _repo_root().path_join("crates/derelict_core/assets/golden_areas/airlock_2x2.json")
	if not FileAccess.file_exists(golden_path):
		push_error("FAIL: missing golden %s" % golden_path)
		quit(1)
		return
	var gf := FileAccess.open(golden_path, FileAccess.READ)
	var loaded: Dictionary = author.load_golden(gf.get_as_text())
	if loaded.has("error"):
		push_error("FAIL: load_golden %s" % loaded["error"])
		quit(1)
		return

	var compiled: Dictionary = author.compile(loaded)
	if compiled.has("error"):
		push_error("FAIL: compile %s" % compiled["error"])
		quit(1)
		return
	var plan: Dictionary = compiled.get("plan", {})
	var floors: Array = plan.get("floor_placements", [])
	var ceilings: Array = plan.get("ceiling_placements", [])
	var placements: Array = plan.get("placements", [])
	print("PLAN floors=%d ceilings=%d placements=%d" % [floors.size(), ceilings.size(), placements.size()])
	if floors.size() != 4:
		push_error("FAIL: airlock_2x2 expected 4 floors, got %d" % floors.size())
		failed = true

	var PreviewScript := load("res://scripts/StructuralPreview.gd")
	var preview = PreviewScript.new()
	root.add_child(preview)
	preview.configure(content_root, false)
	preview.apply_plan(plan)
	print("PREVIEW glb=%d fallback=%d floors=%d walls=%d doorways=%d claimed=%s missing=%s" % [
		preview.glb_count, preview.fallback_count, preview.floor_glb_count,
		preview.wall_glb_count, preview.doorway_glb_count, preview.claimed_kit_preview,
		", ".join(preview.missing_ids)
	])
	print("STATUS %s" % preview.status_text())

	if preview.floor_glb_count != 4:
		push_error("FAIL: expected 4 floor GLBs, got %d" % preview.floor_glb_count)
		failed = true
	if preview.wall_glb_count < 1:
		push_error("FAIL: expected wall GLBs")
		failed = true
	if preview.doorway_glb_count < 1:
		push_error("FAIL: expected doorway GLB")
		failed = true
	if preview.fallback_count != 0:
		push_error("FAIL: CSG fallback used; not claiming kit preview")
		failed = true
	if not preview.claimed_kit_preview:
		push_error("FAIL: kit preview not claimed")
		failed = true

	# Must never load wrapper scenes.
	for id in REQUIRED:
		var tscn := content_root.path_join("scenes/wrappers/structural/ship_structural_v0/%s.tscn" % id)
		if FileAccess.file_exists(tscn):
			print("WRAPPER_PRESENT_BUT_UNUSED %s" % tscn)

	preview.free()
	if failed:
		print("STRUCTURAL_PREVIEW: FAIL")
		quit(1)
	else:
		print("STRUCTURAL_PREVIEW: PASS airlock_2x2 4 floors + walls + doorway from GLBs")
		quit(0)


func _gltf_loads(path: String) -> bool:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state, 0, path.get_base_dir())
	if err != OK:
		return false
	var scene := doc.generate_scene(state)
	if scene == null:
		return false
	scene.free()
	return true


func _resolve_content() -> Dictionary:
	var env := OS.get_environment("SYNAPTIC_SEA_ROOT").strip_edges()
	if not env.is_empty() and DirAccess.open(env) != null:
		return {"path": env.simplify_path(), "offline": false, "source": "env"}
	for c in ["D:/the-synaptic-sea", "D:\\the-synaptic-sea"]:
		if DirAccess.open(c) != null:
			return {"path": c.simplify_path(), "offline": false, "source": "default"}
	return {"path": "", "offline": true, "source": "offline"}


func _repo_root() -> String:
	var dir := ProjectSettings.globalize_path("res://").simplify_path()
	for _i in 6:
		var golden := dir.path_join("crates/derelict_core/assets/golden_areas/airlock_2x2.json")
		if FileAccess.file_exists(golden):
			return dir
		var parent := dir.get_base_dir()
		if parent == dir or parent.is_empty():
			break
		dir = parent
	return dir
