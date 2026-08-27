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
				"id": "radiation_11", "from_room": "airlock_alpha", "to_room": "engineering_upper",
				"from_cell": [0, 0, 0], "to_cell": [0, 0, 1], "module_id": "", "kind": "radiation",
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
