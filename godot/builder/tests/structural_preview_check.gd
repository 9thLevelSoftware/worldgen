extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/structural_preview_check.gd
## Confirms ship_structural_v0 GLBs load and airlock_2x2 previews from kit files.

const REQUIRED := ["floor_1x1", "wall_straight_1x1", "doorway_frame_open_1x1"]
const WEST_DOOR_KEY := "0|v|0|-1"
const WEST_DOOR_POS := Vector3(-2.0, 0.0, 0.0)


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

	var compiled_door: Variant = _placement_pos(placements, WEST_DOOR_KEY)
	if compiled_door == null:
		push_error("FAIL: plan missing west doorway %s" % WEST_DOOR_KEY)
		failed = true
	elif not _near(compiled_door, WEST_DOOR_POS):
		push_error("FAIL: compiled west doorway at %s expected %s" % [compiled_door, WEST_DOOR_POS])
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
	if preview.wall_glb_count != 7:
		push_error("FAIL: expected 7 wall GLBs, got %d" % preview.wall_glb_count)
		failed = true
	if preview.doorway_glb_count != 1:
		push_error("FAIL: expected 1 doorway GLB, got %d" % preview.doorway_glb_count)
		failed = true
	if preview.fallback_count != 0:
		push_error("FAIL: CSG fallback used; not claiming kit preview")
		failed = true
	if not preview.claimed_kit_preview:
		push_error("FAIL: kit preview not claimed")
		failed = true
	if not preview.covers_occupied_floors():
		push_error("FAIL: kit floors do not cover every occupied cell")
		failed = true

	var floor00 = _piece_by_cell(preview, "floor", "0|0|0")
	if floor00 == null:
		push_error("FAIL: missing floor piece for cell 0|0|0")
		failed = true
	elif not _near(floor00.position, Vector3.ZERO):
		push_error("FAIL: floor (0,0) at %s expected (0,0,0)" % floor00.position)
		failed = true
	else:
		print("POSE_OK floor 0|0|0 at %s" % floor00.position)

	var door = _piece_by_edge(preview, WEST_DOOR_KEY)
	if door == null:
		push_error("FAIL: missing west doorway piece %s" % WEST_DOOR_KEY)
		failed = true
	elif not _near(door.position, WEST_DOOR_POS):
		push_error("FAIL: west doorway at %s expected %s" % [door.position, WEST_DOOR_POS])
		failed = true
	else:
		print("POSE_OK doorway %s at %s yaw=%s" % [WEST_DOOR_KEY, door.position, door.rotation_degrees.y])

	if _tree_has_tscn(preview):
		push_error("FAIL: spawned tree instanced a .tscn wrapper")
		failed = true
	else:
		print("NO_TSCN_OK")

	var LatticeScript := load("res://scripts/OccupancyLattice.gd")
	var lattice = LatticeScript.new()
	root.add_child(lattice)
	if not _near(lattice._center(0, 0, 0), Vector3.ZERO):
		push_error("FAIL: occupancy _center(0,0,0) is %s expected (0,0,0)" % lattice._center(0, 0, 0))
		failed = true
	lattice.active_role = "airlock"
	for c in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0)]:
		if not lattice.paint_cell(c):
			push_error("FAIL: occupancy paint %s" % c)
			failed = true
	lattice.set_occupancy_floors_visible(not preview.covers_occupied_floors())
	if lattice.occupancy_floors_visible():
		push_error("FAIL: occupancy floors should hide when every cell has a floor GLB")
		failed = true
	var neighbor := Vector3i(2, 0, 0)
	if not lattice.paint_cell(neighbor):
		push_error("FAIL: paint on void neighbor after occupancy-floor hide")
		failed = true
	elif not lattice.has_occupied(neighbor):
		push_error("FAIL: occupancy missing painted neighbor %s" % neighbor)
		failed = true
	else:
		print("PAINT_AFTER_HIDE_OK %s" % neighbor)

	preview.free()
	lattice.free()
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


func _placement_pos(placements: Array, edge_key: String) -> Variant:
	for rec_v in placements:
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var key := str(rec.get("edge_key", rec.get("key", "")))
		if key == edge_key:
			return _vec3(rec.get("position", []))
	return null


func _piece_by_cell(preview, layer: String, cell_key: String) -> Node3D:
	for n in preview.piece_nodes():
		if str(n.get_meta("layer", "")) != layer:
			continue
		if str(n.get_meta("cell_key", "")) == cell_key:
			return n
	return null


func _piece_by_edge(preview, edge_key: String) -> Node3D:
	for n in preview.piece_nodes():
		if str(n.get_meta("edge_key", "")) == edge_key:
			return n
	return null


func _tree_has_tscn(n: Node) -> bool:
	if str(n.scene_file_path).ends_with(".tscn"):
		return true
	for c in n.get_children():
		if _tree_has_tscn(c):
			return true
	return false


func _vec3(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


func _near(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) < 0.001


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
