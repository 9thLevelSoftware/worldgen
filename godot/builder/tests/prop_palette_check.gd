extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/prop_palette_check.gd
## Palette grouping, interior_zones snap, one-per-cell inspect, proto preview.

var _failed := false


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	_check_palette()
	_check_snap()
	_check_shared_solid_facing()
	_check_preview()
	_check_compile_airlock()
	await process_frame
	await process_frame
	if _failed:
		print("PROP_PALETTE: FAIL")
		quit(1)
	else:
		print("PROP_PALETTE: PASS")
		quit(0)


func _fail(msg: String) -> void:
	push_error("FAIL: %s" % msg)
	_failed = true


func _check_palette() -> void:
	var Palette := load("res://scripts/PaletteDock.gd")
	var dock = Palette.new()
	root.add_child(dock)
	dock.bind_palettes({
		"proto_visual": {"bunk": "generic_locker", "suit_locker": "generic_locker"},
		"furnishing": [
			{"role": "airlock", "proto": "suit_locker", "kind": "Container", "place": "WallAdjacent"},
			{"role": "crew_quarters", "proto": "bunk", "kind": "Furniture", "place": "WallAdjacent"},
			{"role": "airlock", "proto": "door", "kind": "Door", "place": "WallAdjacent"},
		],
		"components": [
			{"id": "locker_wall", "visual_scene_path": "res://assets/imported/props/components/locker_wall.glb", "surface": ""},
		],
		"dressing": [
			{"id": "generic_locker", "visual_scene_path": "res://assets/imported/props/dressing/generic_locker.glb", "surface": "floor"},
			{"id": "cable_tray", "visual_scene_path": "res://assets/imported/props/dressing/cable_tray.glb", "surface": "wall"},
		],
		"objectives": [
			{"id": "supply_cache", "visual_scene_path": "res://assets/imported/props/objectives/supply_cache.glb"},
		],
		"gameplay_props": [
			{"id": "loot_crate", "primitive": "box", "albedo": "#c88a35"},
			{"id": "hatch_wheel", "primitive": "cylinder", "albedo": "#8b9aaa"},
		],
		"slot_components": [
			{"id": "locker_wall", "slot": "wall"},
		],
	})
	dock.set_role_filter("airlock")
	var furn: Array = dock.entries_for_group("furnishing")
	if furn.size() != 1 or str(furn[0]["proto"]) != "suit_locker":
		_fail("airlock furnishing should be suit_locker only, got %s" % furn)
	for e in furn:
		if str(e.get("kind", "")) == "Door":
			_fail("Door leaked into furnishing palette")
	dock.set_role_filter("crew_quarters")
	var bunks: Array = dock.entries_for_group("furnishing")
	if bunks.is_empty() or str(bunks[0]["proto"]) != "bunk":
		_fail("crew_quarters furnishing missing bunk")
	elif not Palette.is_stand_in(bunks[0]):
		_fail("bunk should be labeled preview stand-in")
	elif str(bunks[0]["visual_id"]) != "generic_locker":
		_fail("bunk visual_id should be generic_locker")
	if not Palette.is_wall_adjacent({"place": "WallAdjacent"}):
		_fail("WallAdjacent must refuse center slots")
	if Palette.is_wall_adjacent({"place": "Center"}):
		_fail("Center proto is not wall-adjacent")
	if not Palette.is_wall_adjacent({"surface": "wall"}):
		_fail("dressing surface=wall is wall-adjacent")
	var dressing: Array = dock.entries_for_group("dressing")
	var tray_wall := false
	for e in dressing:
		if str(e["proto"]) == "cable_tray" and Palette.is_wall_adjacent(e):
			tray_wall = true
	if not tray_wall:
		_fail("cable_tray should be wall-adjacent")
	var gp: Array = dock.entries_for_group("gameplay")
	if gp.size() != 2:
		_fail("expected 2 gameplay props, got %d" % gp.size())
	print("PALETTE_OK furnishing/role/stand-in/no-door")
	dock.queue_free()


func _check_snap() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var Palette := load("res://scripts/PaletteDock.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "airlock"
	for c in [
		Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(2, 0, 0),
		Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(2, 1, 0),
		Vector3i(0, 2, 0), Vector3i(1, 2, 0), Vector3i(2, 2, 0),
	]:
		if not lattice.paint_cell(c):
			_fail("paint %s" % c)
	lattice.set_tool(Lattice.TOOL_PROP)
	var locker := {
		"group": "furnishing",
		"role": "airlock",
		"proto": "suit_locker",
		"kind": "Container",
		"place": "WallAdjacent",
		"visual_id": "generic_locker",
		"wall_adjacent": true,
		"stand_in": false,
	}
	lattice.arm_prop(locker)
	if lattice.try_place_prop(Vector3i(1, 0, 0)):
		_fail("place before compile should be blocked")
	var zones := {
		"airlock_01": {
			"reserved_cells": [[0, 0, 0]],
			"wall_slots": [[1, 0, 0], [0, 1, 0], [2, 1, 0]],
			"center_slots": [[1, 1, 0]],
		}
	}
	var plan := {
		"edges": {
			"e_east": {"cell": [1, 0], "deck": 0, "direction": "east", "kind": "SOLID"},
			"e_north": {"cell": [1, 0], "deck": 0, "direction": "north", "kind": "SOLID"},
			"e_west": {"cell": [0, 1], "deck": 0, "direction": "west", "kind": "SOLID"},
		}
	}
	lattice.set_compile_result(zones, plan, true)
	if not lattice.is_reserved_cell(Vector3i(0, 0, 0)):
		_fail("doorway cell should be reserved")
	if lattice.try_place_prop(Vector3i(0, 0, 0)):
		_fail("reserved doorway cell accepted a prop")
	if lattice.try_place_prop(Vector3i(1, 1, 0)):
		_fail("wall-adjacent proto accepted a center slot")
	var east_hit := Vector3(1.0 * 4.0 + 1.9, 0.0, 0.0)
	if not lattice.try_place_prop(Vector3i(1, 0, 0), east_hit):
		_fail("wall slot should accept suit_locker")
	var props: Array = lattice.get_props()
	if props.size() != 1:
		_fail("expected 1 prop, got %d" % props.size())
	else:
		var p: Dictionary = props[0]
		if str(p.get("kind", "")) == "Door":
			_fail("authored Door prop")
		if str(p.get("facing", "")) != "east":
			_fail("facing should be clicked SOLID east, got %s" % p.get("facing", ""))
		if int(p.get("rotation", -1)) != Palette.rotation_from_facing("east"):
			_fail("rotation should init from facing yaw/90")
		if str(p.get("inventory_mode", "")) != "empty":
			_fail("new props must use empty inventory_mode, not materialize stacks")
		if not (p.get("inventory", []) is Array) or (p.get("inventory") as Array).size() != 0:
			_fail("new props must not materialize inventory stacks")
	# Re-click same cell inspects without restamping.
	if lattice.try_place_prop(Vector3i(1, 0, 0), east_hit):
		_fail("re-click restamped a prop")
	if lattice.get_props().size() != 1:
		_fail("re-click created a second prop")
	var selected: Dictionary = lattice.get_selected_prop()
	if selected.is_empty() or int(selected.get("id", 0)) != int(props[0]["id"]):
		_fail("re-click should inspect the existing prop")
	lattice.cycle_prop_rotation(false)
	if int(lattice.get_selected_prop().get("rotation", -1)) != posmod(int(props[0]["rotation"]) + 1, 4):
		_fail("R should cycle rotation 0..=3")
	var crate := {
		"group": "dressing",
		"proto": "generic_crate",
		"kind": "Furniture",
		"place": "Center",
		"visual_id": "generic_crate",
		"wall_adjacent": false,
	}
	lattice.arm_prop(crate)
	if not lattice.try_place_prop(Vector3i(1, 1, 0)):
		_fail("center proto should snap to center_slots")
	if lattice.get_props().size() != 2:
		_fail("expected 2 props after center place")
	if not lattice.remove_prop_at(Vector3i(1, 1, 0)):
		_fail("delete prop at center")
	if lattice.get_props().size() != 1:
		_fail("delete left extra props")
	var door := {"proto": "door", "kind": "Door", "place": "WallAdjacent"}
	lattice.arm_prop(door)
	if not lattice.get_armed_prop().is_empty():
		_fail("Door palette arm should be refused")
	print("SNAP_OK reserved/wall/center/one-per-cell/inspect/facing/rotate")
	lattice.queue_free()


func _check_shared_solid_facing() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "airlock"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint west room cell")
	lattice.create_room()
	lattice.active_role = "dock"
	if not lattice.paint_cell(Vector3i(1, 0, 0)):
		_fail("paint east room cell")
	lattice.set_tool(Lattice.TOOL_PROP)
	lattice.arm_prop({
		"group": "furnishing",
		"role": "dock",
		"proto": "suit_locker",
		"kind": "Container",
		"place": "WallAdjacent",
		"visual_id": "generic_locker",
		"wall_adjacent": true,
	})
	# Compile emits the partition once on the BTreeMap-first cell (west, dir east).
	lattice.set_compile_result({
		"airlock_01": {"reserved_cells": [], "wall_slots": [[0, 0, 0]], "center_slots": []},
		"dock_02": {"reserved_cells": [], "wall_slots": [[1, 0, 0]], "center_slots": []},
	}, {
		"edges": {
			"shared": {
				"cell": [0, 0],
				"deck": 0,
				"direction": "east",
				"opposite_direction": "west",
				"kind": "SOLID",
				"source_cells": [[0, 0, 0], [1, 0, 0]],
			}
		}
	}, true)
	# East cell, west band of the shared wall.
	var west_band := Vector3(1.0 * 4.0 - 1.9, 0.0, 0.0)
	if not lattice.try_place_prop(Vector3i(1, 0, 0), west_band):
		_fail("east wall_slot should accept a prop against the shared SOLID")
	var props: Array = lattice.get_props()
	if props.is_empty():
		_fail("shared SOLID place produced no prop")
	elif str(props[0].get("facing", "")) != "west":
		_fail("east cell west band should face west, got %s" % props[0].get("facing", ""))
	else:
		print("SHARED_SOLID_OK east cell west band facing=west")
	lattice.queue_free()


func _check_preview() -> void:
	var Preview := load("res://scripts/StructuralPreview.gd")
	var preview = Preview.new()
	root.add_child(preview)
	preview.configure("", true)
	var palettes := {
		"proto_visual": {"bunk": "generic_locker"},
		"dressing": [
			{"id": "generic_locker", "visual_scene_path": "res://scenes/wrappers/never.tscn"},
		],
		"gameplay_props": [
			{"id": "loot_crate", "primitive": "box", "albedo": "#c88a35"},
		],
	}
	preview.apply_props([
		{
			"id": 1,
			"kind": "Furniture",
			"proto": "bunk",
			"visual_id": "generic_locker",
			"cell": [0, 1, 0],
			"rotation": 2,
			"facing": "east",
			"locked": false,
			"inventory_mode": "empty",
			"inventory": [],
			"loot_table": null,
		},
		{
			"id": 2,
			"kind": "Container",
			"proto": "loot_crate",
			"visual_id": "",
			"cell": [1, 1, 0],
			"rotation": 0,
			"facing": null,
			"locked": false,
			"inventory_mode": "empty",
			"inventory": [],
			"loot_table": null,
			"primitive": "box",
			"albedo": "#c88a35",
		},
		{
			"id": 3,
			"kind": "Door",
			"proto": "door",
			"visual_id": "",
			"cell": [2, 1, 0],
			"rotation": 0,
		},
	], palettes)
	if preview.prop_nodes().size() != 2:
		_fail("preview should instance 2 props and skip Door, got %d" % preview.prop_nodes().size())
	if _tree_has_tscn(preview):
		_fail("prop preview instanced a .tscn")
	var bunk = _prop_by_proto(preview, "bunk")
	if bunk == null:
		_fail("missing bunk preview node")
	elif not _near(bunk.position, Vector3(0, 0, 4)):
		_fail("bunk at %s expected cell-center (0,0,4)" % bunk.position)
	elif not bool(bunk.get_meta("stand_in", false)):
		_fail("bunk preview should be labeled stand-in")
	elif abs(bunk.rotation_degrees.y - 180.0) > 0.01:
		_fail("bunk yaw should be rotation*90, got %s" % bunk.rotation_degrees.y)
	if not _label_has(bunk, "preview stand-in"):
		_fail("bunk missing preview stand-in Label3D")
	var crate = _prop_by_proto(preview, "loot_crate")
	if crate == null:
		_fail("missing gameplay crate CSG")
	print("PREVIEW_OK csg/stand-in/no-tscn/cell-center")
	preview.queue_free()


func _check_compile_airlock() -> void:
	if not ClassDB.class_exists("DerelictAuthor"):
		print("COMPILE_SKIP DerelictAuthor missing")
		return
	var author = ClassDB.instantiate("DerelictAuthor")
	var golden_path := _repo_root().path_join("crates/derelict_core/assets/golden_areas/airlock_2x2.json")
	if not FileAccess.file_exists(golden_path):
		_fail("missing golden %s" % golden_path)
		return
	var gf := FileAccess.open(golden_path, FileAccess.READ)
	var loaded: Dictionary = author.load_golden(gf.get_as_text())
	if loaded.has("error"):
		_fail("load_golden %s" % loaded["error"])
		return
	var compiled: Dictionary = author.compile(loaded)
	if compiled.has("error"):
		_fail("compile %s" % compiled["error"])
		return
	var zones: Dictionary = compiled.get("zones", {})
	var z: Dictionary = {}
	for k in zones:
		z = zones[k]
		break
	var reserved: Array = z.get("reserved_cells", [])
	var walls: Array = z.get("wall_slots", [])
	if reserved.is_empty():
		_fail("airlock_2x2 expected reserved doorway cell")
	if walls.is_empty():
		_fail("airlock_2x2 expected wall_slots")
	print("ZONES_OK reserved=%d wall=%d center=%d" % [
		reserved.size(), walls.size(), (z.get("center_slots", []) as Array).size()
	])
	var palettes: Dictionary = author.palettes()
	var proto_map: Dictionary = palettes.get("proto_visual", {})
	if str(proto_map.get("bunk", "")) != "generic_locker":
		_fail("palettes proto_visual bunk should be generic_locker")
	var content := _resolve_content()
	if bool(content.get("offline", true)):
		print("GLB_SKIP offline")
		return
	var Preview := load("res://scripts/StructuralPreview.gd")
	var preview = Preview.new()
	root.add_child(preview)
	preview.configure(str(content["path"]), false)
	preview.apply_plan(compiled.get("plan", {}))
	preview.apply_props(loaded.get("props", []), palettes)
	if _tree_has_tscn(preview):
		_fail("airlock prop preview instanced a .tscn")
	if preview.prop_nodes().is_empty():
		_fail("airlock_2x2 suit_locker should preview")
	print("AIRLOCK_PROP_OK glb=%d fallback=%d nodes=%d" % [
		preview.prop_glb_count, preview.prop_fallback_count, preview.prop_nodes().size()
	])
	preview.queue_free()


func _prop_by_proto(preview, proto: String) -> Node3D:
	for n in preview.prop_nodes():
		if str(n.get_meta("proto", "")) == proto:
			return n
	return null


func _label_has(n: Node, text: String) -> bool:
	if n is Label3D and (n as Label3D).text == text:
		return true
	for c in n.get_children():
		if _label_has(c, text):
			return true
	return false


func _tree_has_tscn(n: Node) -> bool:
	if str(n.scene_file_path).ends_with(".tscn"):
		return true
	for c in n.get_children():
		if _tree_has_tscn(c):
			return true
	return false


func _near(a: Vector3, b: Vector3) -> bool:
	return a.distance_to(b) < 0.001


func _resolve_content() -> Dictionary:
	var env := OS.get_environment("SYNAPTIC_SEA_ROOT").strip_edges()
	if not env.is_empty() and DirAccess.open(env) != null:
		return {"path": env.simplify_path(), "offline": false}
	for c in ["D:/the-synaptic-sea", "D:\\the-synaptic-sea"]:
		if DirAccess.open(c) != null:
			return {"path": c.simplify_path(), "offline": false}
	return {"path": "", "offline": true}


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
