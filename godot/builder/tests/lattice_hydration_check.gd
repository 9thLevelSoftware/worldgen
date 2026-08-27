extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/lattice_hydration_check.gd
## Lossless source-document hydration for every lattice-owned GoldenArea field.

var _failed := false


func _initialize() -> void:
	call_deferred("_run_checks")


func _run_checks() -> void:
	var lattice = load("res://scripts/OccupancyLattice.gd").new()
	root.add_child(lattice)
	await process_frame

	var golden := _representative_document()
	var result: Dictionary = lattice.hydrate_document(golden)
	if not str(result.get("error", "")).is_empty():
		_fail("hydrate_document failed: %s" % result["error"])
	else:
		_check_hydrated(lattice)
		_check_reset(lattice)
	_check_exterior_hazard_hydration()
	_check_duplicate_prop_cell_rejected()
	_check_three_way_coalescence()

	lattice.free()
	_finish()


func _check_hydrated(lattice: Node) -> void:
	var rooms: Array = lattice.get_rooms()
	if rooms.size() != 3:
		_fail("expected 3 rooms, got %d" % rooms.size())
	else:
		if int(rooms[0].get("id", 0)) != 4 or str(rooms[0].get("stable_id", "")) != "airlock_alpha":
			_fail("room identifiers were not preserved")
		var first_cells: Array = rooms[0].get("cells", [])
		if first_cells.is_empty() or not (first_cells[0] is Vector2i):
			_fail("room cells were not normalized to Vector2i")
	if lattice.deck_count != 2:
		_fail("deck_count got %d" % lattice.deck_count)
	if lattice.get_portals().size() != 1:
		_fail("portal hydration failed")
	if lattice.get_verticals().size() != 1:
		_fail("vertical hydration failed")
	var props: Array = lattice.get_props()
	if props.size() != 1 or int(props[0].get("id", 0)) != 9:
		_fail("prop hydration failed")
	var hazards: Array = lattice.get_hazards()
	if hazards.size() != 2:
		_fail("hazard buckets did not flatten, got %d" % hazards.size())
	elif str(hazards[0].get("kind", "")) != "timed_fire" or str(hazards[1].get("kind", "")) != "radiation":
		_fail("hazard kinds were not restored from their buckets")
	if not lattice.has_occupied(Vector3i(0, 0, 0)) or not lattice.has_occupied(Vector3i(0, 0, 1)):
		_fail("occupancy index was not rebuilt")
	# The next authored room ID must advance beyond the maximum restored ID.
	lattice.active_role = "cargo"
	if not lattice.paint_cell(Vector3i(10, 10, 0)):
		_fail("could not paint after hydration")
	elif int(lattice.get_selected().get("id", 0)) != 13:
		_fail("next room id was not advanced after hydration")


func _check_reset(lattice: Node) -> void:
	lattice.reset_document()
	if not lattice.get_rooms().is_empty():
		_fail("reset left rooms")
	if not lattice.get_portals().is_empty() or not lattice.get_verticals().is_empty():
		_fail("reset left connections")
	if not lattice.get_props().is_empty() or not lattice.get_hazards().is_empty():
		_fail("reset left authored content")
	if lattice.deck_count != 1 or lattice.active_deck != 0:
		_fail("reset did not restore deck state")
	if lattice.has_pending_click():
		_fail("reset left a pending endpoint")


func _check_exterior_hazard_hydration() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	var document := {
		"topology": {
			"rooms": [{"id": 1, "stable_id": "airlock_01", "role": "airlock", "deck": 0, "cells": [[0, 0]]}],
			"portals": [{"from_room": 1, "to_room": 0, "from_cell": [0, 0, 0], "to_cell": [1, 0, 0], "state": "BREACH", "exterior": true}],
			"verticals": [],
		},
		"props": [],
		"hazards": {
			"source": "authored",
			"fire_zones": [{"id": "fire_01", "from_room": "airlock_01", "to_room": "airlock_01", "from_cell": [0, 0, 0], "to_cell": [1, 0, 0]}],
			"breach_zones": [], "arc_zones": [], "radiation_zones": [],
		},
	}
	var result: Dictionary = lattice.hydrate_document(document)
	if not result.get("ok", false):
		_fail("matching exterior hazard should hydrate: %s" % result.get("error", "unknown"))
	else:
		var hazards: Array = lattice.get_hazards()
		if hazards.size() != 1 or (hazards[0].get("to_cell", []) as Array) != [1, 0, 0]:
			_fail("exterior hazard endpoint was not preserved")
	var unrelated: Dictionary = document.duplicate(true)
	(unrelated["hazards"]["fire_zones"] as Array)[0]["to_cell"] = [-1, 0, 0]
	var rejected: Dictionary = lattice.hydrate_document(unrelated)
	if not str(rejected.get("error", "")).contains("unoccupied cell"):
		_fail("unrelated void hazard should be rejected")
	var mismatched: Dictionary = document.duplicate(true)
	(mismatched["hazards"]["fire_zones"] as Array)[0]["from_room"] = "wrong_room"
	var mismatch_result: Dictionary = lattice.hydrate_document(mismatched)
	if not str(mismatch_result.get("error", "")).contains("unknown room"):
		_fail("unknown hazard room should be rejected")
	else:
		var owned_mismatch: Dictionary = document.duplicate(true)
		(owned_mismatch["topology"]["rooms"] as Array).append({"id": 2, "stable_id": "other_room", "role": "cargo", "deck": 0, "cells": [[2, 0]]})
		(owned_mismatch["hazards"]["fire_zones"] as Array)[0]["from_room"] = "other_room"
		(owned_mismatch["hazards"]["fire_zones"] as Array)[0]["to_room"] = "other_room"
		var owned_result: Dictionary = lattice.hydrate_document(owned_mismatch)
		if not str(owned_result.get("error", "")).contains("from_room does not own"):
			_fail("hazard with mismatched occupied from_cell should be rejected")
	var distant: Dictionary = document.duplicate(true)
	(distant["hazards"]["fire_zones"] as Array)[0]["to_cell"] = [4, 0, 0]
	var distant_result: Dictionary = lattice.hydrate_document(distant)
	if not str(distant_result.get("error", "")).contains("cardinal neighbors"):
		_fail("distant hazard endpoints should be rejected during hydration")
	var different_deck: Dictionary = document.duplicate(true)
	(different_deck["hazards"]["fire_zones"] as Array)[0]["to_cell"] = [2, 0, 1]
	var different_deck_result: Dictionary = lattice.hydrate_document(different_deck)
	if not str(different_deck_result.get("error", "")).contains("same deck"):
		_fail("cross-deck hazard endpoints should be rejected during hydration")
	lattice.free()
	print("EXTERIOR_HAZARD_OK hydration preserves portal-aligned void endpoint")


func _check_three_way_coalescence() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "cargo"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint first coalescence room")
	lattice.create_room()
	lattice.active_role = "bridge"
	if not lattice.paint_cell(Vector3i(1, 0, 0)):
		_fail("paint bridge coalescence room")
	lattice.create_room()
	lattice.active_role = "cargo"
	if not lattice.paint_cell(Vector3i(2, 0, 0)):
		_fail("paint later coalescence room")
	var rooms: Array = lattice.get_rooms()
	if rooms.size() != 3:
		_fail("expected three rooms before role change, got %d" % rooms.size())
	else:
		var first_stable := str(rooms[0].get("stable_id", ""))
		var bridge_id := int(rooms[1].get("id", 0))
		var bridge_stable := str(rooms[1].get("stable_id", ""))
		var later_stable := str(rooms[2].get("stable_id", ""))
		lattice.select_room_id(bridge_id)
		lattice.stamp_role("cargo")
		if lattice.get_rooms().size() != 1:
			_fail("three-way touching rooms did not reach a fixed point")
		var remap: Dictionary = lattice.consume_room_stable_id_remap()
		if str(remap.get(bridge_stable, "")) != first_stable or str(remap.get(later_stable, "")) != first_stable:
			_fail("stable IDs did not remap to retained first room")
	lattice.free()
	print("COALESCE_OK three-way fixed point and stable remap")


func _check_duplicate_prop_cell_rejected() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	var duplicate := _representative_document()
	(duplicate["props"] as Array).append({
		"id": 10, "kind": "Container", "proto": "crate", "visual_id": "crate_a",
		"cell": [0, 0, 0], "rotation": 0,
	})
	var result: Dictionary = lattice.hydrate_document(duplicate)
	if not str(result.get("error", "")).contains("one prop per cell"):
		_fail("hydration accepted multiple props on one occupied cell: %s" % result.get("error", "success"))
	lattice.free()
	print("DUPLICATE_PROP_CELL_OK hydration enforces one prop per cell")


func _representative_document() -> Dictionary:
	return {
		"topology": {
			"rooms": [
				{"id": 4, "stable_id": "airlock_alpha", "role": "airlock", "deck": 0, "cells": [[0, 0], [1, 0]]},
				{"id": 8, "stable_id": "corridor_beta", "role": "corridor", "deck": 0, "cells": [[2, 0]]},
				{"id": 12, "stable_id": "engineering_upper", "role": "engineering", "deck": 1, "cells": [[0, 0]]},
			],
			"portals": [{
				"from_room": 4, "to_room": 8,
				"from_cell": [1, 0, 0], "to_cell": [2, 0, 0],
				"state": "LOCKED", "exterior": false,
			}],
			"verticals": [{
				"from_room": 4, "to_room": 12,
				"from_cell": [0, 0, 0], "to_cell": [0, 0, 1],
			}],
		},
		"props": [{
			"id": 9, "kind": "Container", "proto": "locker", "visual_id": "locker_a",
			"cell": [0, 0, 0], "rotation": 2, "facing": "north", "locked": true,
			"inventory_mode": "explicit", "inventory": [{"item_id": "scrap", "qty": 2}], "loot_table": null,
		}],
		"hazards": {
			"source": "authored",
			"fire_zones": [{
				"id": "fire_07", "from_room": "airlock_alpha", "to_room": "corridor_beta",
				"from_cell": [1, 0, 0], "to_cell": [2, 0, 0], "module_id": "", "kind": "timed_fire",
				"compartment_id": "", "rationale": "test fire",
			}],
			"breach_zones": [], "arc_zones": [],
			"radiation_zones": [{
				"id": "radiation_11", "from_room": "airlock_alpha", "to_room": "airlock_alpha",
				"from_cell": [0, 0, 0], "to_cell": [0, 0, 0], "module_id": "", "kind": "radiation",
				"compartment_id": "", "rationale": "test radiation",
			}],
		},
	}


func _finish() -> void:
	if _failed:
		print("LATTICE_HYDRATION: FAIL")
		quit(1)
	else:
		print("LATTICE_HYDRATION: PASS")
		quit(0)


func _fail(message: String) -> void:
	push_error("FAIL: %s" % message)
	_failed = true
