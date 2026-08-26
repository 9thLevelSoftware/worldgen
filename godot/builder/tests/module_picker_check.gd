extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/module_picker_check.gd
## Module picker: legal ids, hatch note, greyed floors, FloorBadModule, no portals[].module_id.

const Inspector := preload("res://scripts/InspectorDock.gd")
const Lattice := preload("res://scripts/OccupancyLattice.gd")

const WEST_DOOR := "0|v|0|-1"


func _initialize() -> void:
	var failed := false

	if Inspector.HATCH_NOTE != "visual mismatch, legal id":
		push_error("FAIL: hatch note must be 'visual mismatch, legal id'")
		failed = true
	var hatch := Inspector.module_note({"kind": "portal", "state": "HATCH"})
	if hatch != Inspector.HATCH_NOTE:
		push_error("FAIL: module_note hatch got '%s'" % hatch)
		failed = true
	else:
		print("HATCH_NOTE_OK")

	if not Inspector.is_greyed_floor("floor_2x1"):
		push_error("FAIL: floor_2x1 should be greyed")
		failed = true
	if Inspector.is_greyed_floor("floor_1x1") or Inspector.is_greyed_floor("corridor_floor_1x1"):
		push_error("FAIL: FLOOR_MODULES must not be greyed")
		failed = true
	for id in Inspector.GREYED_FLOOR_MODULES:
		if not Inspector.is_greyed_floor(id):
			push_error("FAIL: %s should be greyed" % id)
			failed = true
	print("GREYED_OK %s" % ", ".join(Inspector.GREYED_FLOOR_MODULES))

	var merged := Inspector.merge_legal_ids("floor", PackedStringArray(["floor_1x1"]), "")
	for id in Inspector.GREYED_FLOOR_MODULES:
		if merged.find(id) < 0:
			push_error("FAIL: merge_legal_ids missing greyed %s" % id)
			failed = true
	print("MERGE_OK count=%d" % merged.size())

	var vertex_note := Inspector.module_note({
		"kind": "vertex",
		"state": "outer",
		"module_id": "wall_straight_1x1",
		"dressed_id": "wall_outer_corner",
		"overridden": true,
	})
	if vertex_note.find("vertex-dressed wall_outer_corner") < 0:
		push_error("FAIL: vertex override note got '%s'" % vertex_note)
		failed = true

	var lattice = Lattice.new()
	root.add_child(lattice)
	var west := lattice.edge_key_between(Vector3i(0, 0, 0), Vector3i(-1, 0, 0))
	if west != WEST_DOOR:
		push_error("FAIL: west edge_key %s expected %s" % [west, WEST_DOOR])
		failed = true
	else:
		print("EDGE_KEY_OK %s" % west)

	lattice.active_role = "airlock"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		push_error("FAIL: paint (0,0,0)")
		failed = true
	var floor_sel: Dictionary = lattice.pick_compiled_at(Vector3i(0, 0, 0), Vector3(0, 0, 0))
	if str(floor_sel.get("kind", "")) != "floor" or str(floor_sel.get("key", "")) != "0|0|0":
		push_error("FAIL: interior pick should be floor 0|0|0, got %s" % floor_sel)
		failed = true
	else:
		print("FLOOR_PICK_OK %s role=%s" % [floor_sel.get("key"), floor_sel.get("state")])
	var wall_sel: Dictionary = lattice.pick_compiled_at(Vector3i(0, 0, 0), Vector3(-1.9, 0, 0))
	if str(wall_sel.get("kind", "")) != "wall" or str(wall_sel.get("key", "")) != WEST_DOOR:
		push_error("FAIL: west-band pick should be wall %s, got %s" % [WEST_DOOR, wall_sel])
		failed = true
	else:
		print("WALL_PICK_OK %s" % wall_sel.get("key"))

	if not ClassDB.class_exists("DerelictAuthor"):
		push_error("FAIL: DerelictAuthor missing")
		lattice.free()
		quit(1)
		return

	var author = ClassDB.instantiate("DerelictAuthor")
	var floor_airlock: PackedStringArray = author.legal_modules("floor", "airlock")
	if floor_airlock.is_empty() or floor_airlock[0] != "corridor_floor_1x1":
		push_error("FAIL: connective floor default got %s" % floor_airlock)
		failed = true
	else:
		print("LEGAL_FLOOR_CONNECTIVE_OK %s" % floor_airlock[0])
	var floor_bridge: PackedStringArray = author.legal_modules("floor", "bridge")
	if floor_bridge.is_empty() or floor_bridge[0] != "floor_1x1":
		push_error("FAIL: other floor default got %s" % floor_bridge)
		failed = true
	else:
		print("LEGAL_FLOOR_OTHER_OK %s" % floor_bridge[0])
	var wall_ids: PackedStringArray = author.legal_modules("wall", "SOLID")
	if wall_ids.is_empty() or wall_ids[0] != "wall_straight_1x1":
		push_error("FAIL: solid wall default got %s" % wall_ids)
		failed = true
	var door_ids: PackedStringArray = author.legal_modules("portal", "DOOR")
	if door_ids.is_empty() or door_ids[0] != "doorway_frame_open_1x1":
		push_error("FAIL: door default got %s" % door_ids)
		failed = true
	var locked_ids: PackedStringArray = author.legal_modules("portal", "LOCKED")
	if locked_ids.is_empty() or locked_ids[0] != "doorway_frame_blocked_1x1":
		push_error("FAIL: locked default got %s" % locked_ids)
		failed = true
	var hatch_ids: PackedStringArray = author.legal_modules("portal", "HATCH")
	if hatch_ids.is_empty() or hatch_ids[0] != "bulkhead_portal_2x1":
		push_error("FAIL: hatch default got %s" % hatch_ids)
		failed = true
	else:
		print("LEGAL_HATCH_OK %s" % hatch_ids[0])
	var ceil_ids: PackedStringArray = author.legal_modules("ceiling", "")
	if ceil_ids.is_empty() or ceil_ids[0] != "ceiling_cap_1x1":
		push_error("FAIL: ceiling default got %s" % ceil_ids)
		failed = true
	for pair in [["inner", "wall_inner_corner"], ["outer", "wall_outer_corner"], ["t", "wall_t_junction"]]:
		var vids: PackedStringArray = author.legal_modules("vertex", str(pair[0]))
		if vids.is_empty() or vids[0] != str(pair[1]):
			push_error("FAIL: vertex %s default got %s" % [pair[0], vids])
			failed = true
	var breach_ids: PackedStringArray = author.legal_modules("portal", "BREACH")
	if not breach_ids.is_empty():
		push_error("FAIL: BREACH legal_modules should be empty, got %s" % breach_ids)
		failed = true

	var golden_path := _repo_root().path_join("crates/derelict_core/assets/golden_areas/airlock_2x2.json")
	if not FileAccess.file_exists(golden_path):
		push_error("FAIL: missing golden %s" % golden_path)
		lattice.free()
		quit(1)
		return
	var gf := FileAccess.open(golden_path, FileAccess.READ)
	var loaded: Dictionary = author.load_golden(gf.get_as_text())
	if loaded.has("error"):
		push_error("FAIL: load_golden %s" % loaded["error"])
		lattice.free()
		quit(1)
		return
	for p in loaded.get("topology", {}).get("portals", []):
		if p is Dictionary and (p as Dictionary).has("module_id"):
			push_error("FAIL: loaded portal has module_id")
			failed = true

	var ov: Dictionary = loaded.get("module_overrides", {})
	if not (ov.get("floors", {}) is Dictionary):
		push_error("FAIL: module_overrides.floors missing")
		failed = true
	(ov["floors"] as Dictionary)["0|0|0"] = "floor_2x1"
	loaded["module_overrides"] = ov
	var compiled: Dictionary = author.compile(loaded)
	if compiled.has("error"):
		push_error("FAIL: compile %s" % compiled["error"])
		failed = true
	else:
		var issues: Array = compiled.get("issues", [])
		var saw_bad := false
		for iss in issues:
			if iss is Dictionary and str(iss.get("code", "")) == "FloorBadModule":
				saw_bad = true
				print("FLOOR_BAD_MODULE_OK %s" % iss.get("detail", ""))
		if not saw_bad:
			push_error("FAIL: expected FloorBadModule, got %s" % issues)
			failed = true
		var floors: Array = compiled.get("plan", {}).get("floor_placements", [])
		var saw_override := false
		for rec in floors:
			if rec is Dictionary and str(rec.get("cell_key", "")) == "0|0|0":
				if str(rec.get("module_id", "")) == "floor_2x1":
					saw_override = true
		if not saw_override:
			push_error("FAIL: compile_authored did not apply floor_2x1 override")
			failed = true

	var saved := str(author.save_golden(loaded))
	if saved.contains("\"module_id\"") and saved.contains("portals"):
		var parsed: Variant = JSON.parse_string(saved)
		if parsed is Dictionary:
			for p in parsed.get("topology", {}).get("portals", []):
				if p is Dictionary and (p as Dictionary).has("module_id"):
					push_error("FAIL: save_golden wrote portals[].module_id")
					failed = true

	var dock = Inspector.new()
	root.add_child(dock)
	var emitted: Array = []
	dock.module_override_set.connect(func(ov_map: String, key: String, module_id: String) -> void:
		emitted.append([ov_map, key, module_id])
	)
	var legal := Inspector.merge_legal_ids("floor", PackedStringArray(["corridor_floor_1x1"]), "corridor_floor_1x1")
	dock.bind_module({
		"ov_map": "floors",
		"kind": "floor",
		"state": "airlock",
		"key": "0|0|0",
		"module_id": "corridor_floor_1x1",
		"default_id": "corridor_floor_1x1",
	}, legal)
	var grey_idx := -1
	for i in dock._mod_list.item_count:
		if str(dock._mod_list.get_item_metadata(i)) == "floor_2x1":
			grey_idx = i
			break
	if grey_idx < 0:
		push_error("FAIL: inspector list missing greyed floor_2x1")
		failed = true
	else:
		dock._on_module_item_selected(grey_idx)
		if emitted.is_empty() or emitted[0][0] != "floors" or emitted[0][2] != "floor_2x1":
			push_error("FAIL: assigning greyed floor did not write override %s" % emitted)
			failed = true
		else:
			print("GREYED_ASSIGN_OK floors 0|0|0 → floor_2x1")

	lattice.free()
	dock.free()
	if failed:
		print("MODULE_PICKER: FAIL")
		quit(1)
	else:
		print("MODULE_PICKER: PASS")
		quit(0)


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
