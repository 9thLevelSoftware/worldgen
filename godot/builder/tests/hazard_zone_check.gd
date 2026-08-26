extends SceneTree
## Headless check:
##   godot --headless --path godot/builder -s tests/hazard_zone_check.gd
## Link-shaped hazard authoring, COMPARTMENT_FOR_ROLE, inspector honesty.

var _failed := false


func _initialize() -> void:
	# SceneTree -s: node _ready() runs after _initialize. Defer tree-backed checks.
	call_deferred("_run_checks")


func _run_checks() -> void:
	_check_compartment_map()
	_check_two_cell_zone()
	_check_pending_not_a_record()
	_check_reclick_inspects()
	_check_void_neighbor()
	_check_stamp_role_compartment()
	_check_portal_edge()
	_check_unmapped_role()
	_check_inspector_honesty()
	_check_preview_midpoint()
	_check_phase4_tab()
	if _failed:
		print("HAZARD_ZONE: FAIL")
		quit(1)
	else:
		print("HAZARD_ZONE: PASS")
		quit(0)


func _fail(msg: String) -> void:
	push_error("FAIL: %s" % msg)
	_failed = true


func _check_compartment_map() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	if Lattice.compartment_for_role("bridge") != "bridge":
		_fail("bridge → bridge")
	if Lattice.compartment_for_role("cockpit") != "bridge":
		_fail("cockpit → bridge")
	if Lattice.compartment_for_role("engineering") != "engineering":
		_fail("engineering → engineering")
	if Lattice.compartment_for_role("reactor") != "engineering":
		_fail("reactor → engineering")
	if Lattice.compartment_for_role("engine_bay") != "engineering":
		_fail("engine_bay → engineering")
	if Lattice.compartment_for_role("hydroponics") != "hydroponics":
		_fail("hydroponics → hydroponics")
	if Lattice.compartment_for_role("cargo") != "cargo":
		_fail("cargo → cargo")
	if Lattice.compartment_for_role("storage") != "cargo":
		_fail("storage → cargo")
	if Lattice.compartment_for_role("airlock") != "":
		_fail("airlock should have no hull compartment")
	if Lattice.compartment_for_role("corridor") != "":
		_fail("corridor should have no hull compartment")
	print("COMPARTMENT_OK mapping")


func _check_two_cell_zone() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "engineering"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint (0,0)")
	if not lattice.paint_cell(Vector3i(1, 0, 0)):
		_fail("paint (1,0)")
	lattice.set_tool(Lattice.TOOL_HAZARD)
	lattice.stamp_hazard_kind("timed_fire")
	if not lattice.try_place_hazard(Vector3i(0, 0, 0), Vector3i(1, 0, 0)):
		_fail("two-cell fire zone")
	var zones: Array = lattice.get_hazards()
	if zones.size() != 1:
		_fail("expected 1 fire zone, got %d" % zones.size())
	else:
		var z: Dictionary = zones[0]
		if str(z.get("kind", "")) != "timed_fire":
			_fail("kind timed_fire, got %s" % z.get("kind", ""))
		if str(z.get("from_room", "")) != str(z.get("to_room", "")):
			_fail("same-room fire should use matching stable_ids")
		if str(z.get("compartment_id", "")) != "engineering":
			_fail("engineering fire should map compartment_id=engineering, got %s" % z.get("compartment_id", ""))
		var from_c: Array = z.get("from_cell", [])
		var to_c: Array = z.get("to_cell", [])
		if from_c.size() != 3 or to_c.size() != 3:
			_fail("cells must be [x,y,deck] length 3")
		if str(z.get("id", "")).is_empty():
			_fail("zone id must be non-empty")
	var dto: Dictionary = lattice.get_hazards_dto()
	if str(dto.get("source", "")) != "authored":
		_fail("hazard_source must be authored")
	if (dto.get("fire_zones", []) as Array).size() != 1:
		_fail("fire_zones bucket")
	if (dto.get("breach_zones", []) as Array).size() != 0:
		_fail("empty breach_zones should stay empty, not a dummy record")
	print("TWO_CELL_OK fire same-room engineering")
	lattice.free()


func _check_pending_not_a_record() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "cargo"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint pending start")
	if not lattice.paint_cell(Vector3i(1, 0, 0)):
		_fail("paint pending neighbor")
	lattice.set_tool(Lattice.TOOL_HAZARD)
	lattice.stamp_hazard_kind("hull_breach")
	lattice.try_hazard_click(Vector3i(0, 0, 0))
	if not lattice.has_pending_click():
		_fail("first click should be pending, not a DTO row")
	if not lattice.get_hazards().is_empty():
		_fail("pending click created an undeletable empty zone")
	lattice.cancel_pending()
	if lattice.has_pending_click():
		_fail("esc/cancel should drop pending")
	if not lattice.get_hazards().is_empty():
		_fail("cancel left a zone record")
	print("PENDING_OK no empty records")
	lattice.free()


func _check_reclick_inspects() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "bridge"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint reclick a")
	if not lattice.paint_cell(Vector3i(1, 0, 0)):
		_fail("paint reclick b")
	lattice.set_tool(Lattice.TOOL_HAZARD)
	lattice.stamp_hazard_kind("electrical_arc")
	if not lattice.try_place_hazard(Vector3i(0, 0, 0), Vector3i(1, 0, 0)):
		_fail("place arc")
	var first_id := str(lattice.get_selected_hazard().get("id", ""))
	# Re-click same endpoints / same kind inspects, does not restamp a second zone.
	if not lattice.try_place_hazard(Vector3i(1, 0, 0), Vector3i(0, 0, 0)):
		_fail("re-click should select existing")
	if lattice.get_hazards().size() != 1:
		_fail("re-click created a second zone (%d)" % lattice.get_hazards().size())
	var sel: Dictionary = lattice.get_selected_hazard()
	if str(sel.get("id", "")) != first_id:
		_fail("re-click restamped id")
	if str(sel.get("kind", "")) != "electrical_arc":
		_fail("re-click restamped kind")
	# LMB same-kind re-click inspects (the authoring gesture, not only try_place_hazard).
	var east_hit := Vector3(0.0 * 4.0 + 1.9, 0.0, 0.0)
	lattice.try_hazard_click(Vector3i(0, 0, 0), east_hit)
	if lattice.get_hazards().size() != 1:
		_fail("LMB same-kind re-click created a second zone")
	if str(lattice.get_selected_hazard().get("id", "")) != first_id:
		_fail("LMB re-click restamped id")
	# A different kind on the same link is a second overlay, not a restamp.
	lattice.stamp_hazard_kind("radiation")
	if not lattice.try_hazard_click(Vector3i(0, 0, 0), east_hit):
		_fail("LMB different kind should add a second overlay")
	if lattice.get_hazards().size() != 2:
		_fail("expected arc+radiation overlays on one link, got %d" % lattice.get_hazards().size())
	print("RECLICK_OK inspect no restamp")
	lattice.free()


func _check_void_neighbor() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "cargo"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint void-neighbor origin")
	lattice.set_tool(Lattice.TOOL_HAZARD)
	lattice.stamp_hazard_kind("timed_fire")
	if not lattice.try_place_hazard(Vector3i(0, 0, 0), Vector3i(1, 0, 0)):
		_fail("void-neighbor fire")
	var zones: Array = lattice.get_hazards()
	if zones.size() != 1:
		_fail("void-neighbor expected 1 zone, got %d" % zones.size())
	else:
		var z: Dictionary = zones[0]
		var from_c: Array = z.get("from_cell", [])
		var to_c: Array = z.get("to_cell", [])
		if from_c != to_c:
			_fail("void neighbor should duplicate from_cell, got %s → %s" % [from_c, to_c])
	var first_id := str(lattice.get_selected_hazard().get("id", ""))
	if not lattice.try_place_hazard(Vector3i(0, 0, 0), Vector3i(1, 0, 0)):
		_fail("void-neighbor re-click should inspect")
	if lattice.get_hazards().size() != 1:
		_fail("void-neighbor re-click restamped (%d)" % lattice.get_hazards().size())
	if str(lattice.get_selected_hazard().get("id", "")) != first_id:
		_fail("void-neighbor re-click changed id")
	var east_hit := Vector3(0.0 * 4.0 + 1.9, 0.0, 0.0)
	lattice.try_hazard_click(Vector3i(0, 0, 0), east_hit)
	if lattice.get_hazards().size() != 1:
		_fail("void-neighbor LMB re-click restamped")
	print("VOID_NEIGHBOR_OK collapsed pair inspects")
	lattice.free()


func _check_stamp_role_compartment() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "corridor"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint corridor a")
	if not lattice.paint_cell(Vector3i(1, 0, 0)):
		_fail("paint corridor b")
	lattice.set_tool(Lattice.TOOL_HAZARD)
	lattice.stamp_hazard_kind("timed_fire")
	if not lattice.try_place_hazard(Vector3i(0, 0, 0), Vector3i(1, 0, 0)):
		_fail("fire on corridor")
	if str(lattice.get_hazards()[0].get("compartment_id", "")) != "":
		_fail("corridor fire should start with empty compartment_id")
	lattice.stamp_role("engineering")
	if str(lattice.get_hazards()[0].get("compartment_id", "")) != "engineering":
		_fail("stamp_role engineering should refresh compartment_id, got %s" % lattice.get_hazards()[0].get("compartment_id", ""))
	lattice.stamp_role("airlock")
	if str(lattice.get_hazards()[0].get("compartment_id", "")) != "":
		_fail("stamp_role airlock should clear stale engineering cid")
	print("STAMP_ROLE_OK compartment_id refresh")
	lattice.free()


func _check_portal_edge() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "cargo"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint west cargo")
	lattice.create_room()
	lattice.active_role = "bridge"
	if not lattice.paint_cell(Vector3i(1, 0, 0)):
		_fail("paint east bridge")
	if not lattice.try_place_portal(Vector3i(0, 0, 0), Vector3i(1, 0, 0)):
		_fail("portal between cargo and bridge")
	lattice.set_tool(Lattice.TOOL_HAZARD)
	lattice.stamp_hazard_kind("timed_fire")
	# East band of west cell is the portal edge.
	var east_hit := Vector3(0.0 * 4.0 + 1.9, 0.0, 0.0)
	if not lattice.try_hazard_click(Vector3i(0, 0, 0), east_hit):
		_fail("portal-edge click should author a zone")
	var zones: Array = lattice.get_hazards()
	if zones.size() != 1:
		_fail("portal-edge expected 1 zone, got %d" % zones.size())
	else:
		var z: Dictionary = zones[0]
		if str(z.get("from_room", "")) == str(z.get("to_room", "")):
			_fail("portal-aligned zone should keep both rooms")
		if str(z.get("kind", "")) != "timed_fire":
			_fail("portal fire kind")
		# from_room is cargo; compartment_id cargo. Unmapped would be empty.
		if str(z.get("compartment_id", "")) != "cargo":
			_fail("portal from cargo should map cargo, got %s" % z.get("compartment_id", ""))
		var from_c: Array = z.get("from_cell", [])
		var to_c: Array = z.get("to_cell", [])
		if from_c.size() != 3 or to_c.size() != 3:
			_fail("portal zone cells length 3")
	# Re-click the same portal edge inspects, no second fire zone.
	lattice.try_hazard_click(Vector3i(0, 0, 0), east_hit)
	if lattice.get_hazards().size() != 1:
		_fail("portal re-click restamped a zone")
	print("PORTAL_EDGE_OK one-click link zone")
	lattice.free()


func _check_unmapped_role() -> void:
	var Lattice := load("res://scripts/OccupancyLattice.gd")
	var lattice = Lattice.new()
	root.add_child(lattice)
	lattice.active_role = "airlock"
	if not lattice.paint_cell(Vector3i(0, 0, 0)):
		_fail("paint airlock a")
	if not lattice.paint_cell(Vector3i(1, 0, 0)):
		_fail("paint airlock b")
	lattice.set_tool(Lattice.TOOL_HAZARD)
	lattice.stamp_hazard_kind("hull_breach")
	if not lattice.try_place_hazard(Vector3i(0, 0, 0), Vector3i(1, 0, 0)):
		_fail("airlock breach visual")
	var z: Dictionary = lattice.get_selected_hazard()
	if str(z.get("compartment_id", "")) != "":
		_fail("airlock should stay preview-only (empty compartment_id)")
	if str(z.get("from_room", "")) == "":
		_fail("from_room stable_id required")
	print("UNMAPPED_OK preview-only airlock")
	lattice.free()


func _check_inspector_honesty() -> void:
	var Inspector := load("res://scripts/InspectorDock.gd")
	var dock = Inspector.new()
	root.add_child(dock)
	var mapped: String = dock.atmosphere_honesty_text("engineering")
	if mapped.find("field_atmosphere") < 0:
		_fail("mapped atmosphere copy should mention field_atmosphere")
	if mapped.find("no live ignite") < 0:
		_fail("mapped atmosphere copy should say no live ignite")
	var unmapped: String = dock.atmosphere_honesty_text("airlock")
	if unmapped.find("preview only") < 0:
		_fail("unmapped atmosphere should be preview only")
	var hz: String = dock.hazard_honesty_text("")
	if hz.find("no live ignite") < 0 or hz.find("no hull compartment") < 0:
		_fail("empty compartment hazard honesty")
	dock.bind_hazard({
		"id": "timed_fire_01",
		"from_room": "eng_01",
		"to_room": "eng_01",
		"from_cell": [0, 0, 0],
		"to_cell": [1, 0, 0],
		"module_id": "",
		"kind": "timed_fire",
		"compartment_id": "engineering",
		"rationale": "",
	})
	var hz_mapped: String = dock.hazard_honesty_text("engineering")
	if hz_mapped.find("no live ignite") < 0:
		_fail("mapped hazard honesty")
	print("HONESTY_OK inspector copy")
	dock.free()


func _check_preview_midpoint() -> void:
	var Preview := load("res://scripts/StructuralPreview.gd")
	var preview = Preview.new()
	root.add_child(preview)
	preview.apply_hazards([
		{
			"id": "timed_fire_01",
			"kind": "timed_fire",
			"from_cell": [0, 0, 0],
			"to_cell": [1, 0, 0],
		},
		{
			"id": "hull_breach_01",
			"kind": "hull_breach",
			"from_cell": [2, 0, 0],
			"to_cell": [2, 0, 0],
		},
	])
	if preview.hazard_nodes().size() != 2:
		_fail("preview should spawn 2 hazard volumes, got %d" % preview.hazard_nodes().size())
	else:
		var fire: Node3D = preview.hazard_nodes()[0]
		var expect := Vector3(2.0, 1.2, 0.0)
		if fire.position.distance_to(expect) > 0.05:
			_fail("fire midpoint %s expected %s" % [fire.position, expect])
		if str(fire.get_meta("kind", "")) != "timed_fire":
			_fail("preview meta kind")
	print("PREVIEW_OK midpoint volumes")
	preview.free()


func _check_phase4_tab() -> void:
	var scene = load("res://builder.tscn")
	if scene == null:
		_fail("builder.tscn missing")
		return
	var app = scene.instantiate()
	root.add_child(app)
	var bar: TabBar = app.get_node("%PhaseBar")
	if bar == null or bar.tab_count < 4:
		_fail("PhaseBar missing 4 tabs")
	else:
		if bar.get_tab_title(3).find("Hazard") < 0:
			_fail("tab 4 should be Hazards, got %s" % bar.get_tab_title(3))
		if bar.is_tab_disabled(3):
			_fail("Phase 4 Hazards tab should be enabled")
		if not bar.is_tab_disabled(2):
			_fail("Phase 3 Assets should stay disabled (module picker is a later PR)")
	app.free()
	print("PHASE4_OK tab enabled")
