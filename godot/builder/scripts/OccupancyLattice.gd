class_name OccupancyLattice
extends Node3D
## 3D occupancy lattice (not a TileMapLayer). Cells snap to CELL_SIZE_M.
## Occupancy paint/erase plus click-click portals, stacked verticals, and
## link-shaped hazard zones (loader from_cell/to_cell overlays).

signal occupancy_changed
signal room_selected(room: Dictionary)
signal portal_selected(portal: Dictionary)
signal vertical_selected(vertical: Dictionary)
signal prop_selected(prop: Dictionary)
signal props_changed
signal piece_selected(sel: Dictionary)
signal hazard_selected(zone: Dictionary)
signal hazards_changed
signal deck_changed(deck: int)
signal hover_info(text: String)
signal tool_changed(tool: String)
signal pending_changed(active: bool, cell: Vector3i)

const _PALETTE := preload("res://scripts/PaletteDock.gd")

const CELL_SIZE_M := 4.0
const DECK_HEIGHT_M := 4.0
const MAX_DECKS := 8
const AABB_MIN := -32
const AABB_MAX := 31
const ISO_YAW := 45.0
const ISO_PITCH := -35.264
const CARDINALS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
]

## Canonical Role::name() spellings; palette and inspector share this list.
const ROLES: PackedStringArray = [
	"airlock", "dock", "corridor", "main_spine", "hub", "ramp", "elevator",
	"bridge", "engineering", "reactor", "life_support", "maintenance",
	"cargo", "hangar", "storage", "armory", "security", "medical",
	"crew_quarters", "mess_hall", "compartment",
]

const TOOL_PAINT := "paint"
const TOOL_PORTAL := "portal"
const TOOL_VERTICAL := "vertical"
const TOOL_PROP := "prop"
const TOOL_ASSET := "asset"
const TOOL_HAZARD := "hazard"

## EdgeKind::name() portal states only (not SOLID/OPEN).
const PORTAL_STATES: PackedStringArray = ["DOOR", "LOCKED", "HATCH", "BREACH"]

## Loader LinkZone.kind vocabulary. One shape for every overlay type.
const HAZARD_KINDS: PackedStringArray = [
	"timed_fire", "hull_breach", "electrical_arc", "radiation",
]

const HAZARD_BUCKET := {
	"timed_fire": "fire_zones",
	"hull_breach": "breach_zones",
	"electrical_arc": "arc_zones",
	"radiation": "radiation_zones",
}

const HAZARD_COLORS := {
	"timed_fire": Color(1.0, 0.62, 0.14),
	"hull_breach": Color(0.95, 0.22, 0.20),
	"electrical_arc": Color(0.12, 0.86, 0.95),
	"radiation": Color(0.55, 0.95, 0.22),
}

## playable_generated_ship.gd COMPARTMENT_FOR_ROLE. Unmapped roles stay visual.
## hydroponics/cockpit/engine_bay are loader aliases; the role palette cannot stamp hydroponics.
const COMPARTMENT_FOR_ROLE := {
	"bridge": "bridge",
	"cockpit": "bridge",
	"engineering": "engineering",
	"reactor": "engineering",
	"engine_bay": "engineering",
	"hydroponics": "hydroponics",
	"cargo": "cargo",
	"storage": "cargo",
}

const STATE_COLORS := {
	"DOOR": Color(0.25, 0.85, 0.95),
	"LOCKED": Color(0.95, 0.68, 0.22),
	"HATCH": Color(0.72, 0.48, 0.95),
	"BREACH": Color(0.95, 0.28, 0.32),
}

const ROLE_COLORS := {
	"airlock": Color(0.35, 0.72, 0.95),
	"dock": Color(0.45, 0.62, 0.95),
	"corridor": Color(0.58, 0.60, 0.64),
	"main_spine": Color(0.52, 0.56, 0.62),
	"hub": Color(0.70, 0.68, 0.52),
	"ramp": Color(0.62, 0.58, 0.48),
	"elevator": Color(0.55, 0.55, 0.72),
	"bridge": Color(0.40, 0.78, 0.62),
	"engineering": Color(0.92, 0.55, 0.28),
	"reactor": Color(0.95, 0.38, 0.22),
	"life_support": Color(0.35, 0.82, 0.70),
	"maintenance": Color(0.62, 0.58, 0.42),
	"cargo": Color(0.78, 0.62, 0.32),
	"hangar": Color(0.68, 0.72, 0.38),
	"storage": Color(0.72, 0.64, 0.40),
	"armory": Color(0.78, 0.42, 0.42),
	"security": Color(0.70, 0.40, 0.50),
	"medical": Color(0.45, 0.82, 0.78),
	"crew_quarters": Color(0.48, 0.70, 0.55),
	"mess_hall": Color(0.58, 0.78, 0.48),
	"compartment": Color(0.55, 0.58, 0.60),
}

var active_role: String = "corridor"
var active_deck: int = 0
var deck_count: int = 1
var active_tool: String = TOOL_PAINT
var active_portal_state: String = "DOOR"
var active_hazard_kind: String = "timed_fire"

var _rooms: Array[Dictionary] = []
var _occupancy: Dictionary = {} # "deck|x|y" -> room id
var _portals: Array[Dictionary] = []
var _verticals: Array[Dictionary] = []
var _props: Array[Dictionary] = []
var _hazards: Array[Dictionary] = []
var _selected_id: int = 0
var _selected_kind: String = "room"
var _selected_portal: int = -1
var _selected_vertical: int = -1
var _selected_prop: int = -1
var _selected_hazard: int = -1
var _next_id: int = 1
var _next_prop_id: int = 1
var _next_hazard_serial: int = 1
var _armed_prop: Dictionary = {}
var _prop_ready := false
var _show_slots := false
var _rotation_offset: int = 0
var _reserved: Dictionary = {}
var _wall_slots: Dictionary = {}
var _center_slots: Dictionary = {}
var _solid_dirs: Dictionary = {} # cell key -> PackedStringArray
var _has_pending := false
var _pending_cell := Vector3i.ZERO
var _asset_sel: Dictionary = {}

var _camera: Camera3D
var _pivot: Node3D
var _floors: Node3D
var _floor_boxes: Dictionary = {} # "deck|x|y" -> CSGBox3D
var _links: Node3D
var _portal_boxes: Dictionary = {}
var _vertical_boxes: Dictionary = {}
var _hazard_root: Node3D
var _hazard_boxes: Dictionary = {}
var _slots: Node3D
var _slot_boxes: Dictionary = {}
var _grid: MeshInstance3D
var _ghost: MeshInstance3D
var _anchor: MeshInstance3D
var _iso := true
var _yaw := ISO_YAW
var _pitch := ISO_PITCH
var _distance := 52.0
var _pan := Vector3.ZERO
var _lmb := false
var _rmb := false
var _orbiting := false
var _panning := false
var _paint_drag := false
var _last_screen := Vector2.ZERO
var _has_last_screen := false
var _last_hit := Vector3.ZERO


func _ready() -> void:
	_build_world()
	_rebuild_grid()
	_apply_camera()


## Clear every authored field while preserving camera and palette preferences.
## This is the document-lifecycle reset boundary; callers never reach into the
## split room/link/prop/hazard stores directly.
func reset_document() -> void:
	_clear_document_state()
	_refresh_document_visuals()
	occupancy_changed.emit()
	props_changed.emit()
	hazards_changed.emit()
	room_selected.emit({})


## Restore all lattice-owned GoldenArea content without compiling or pruning it.
## Invalid source fails before the live document is changed, so opening a file
## cannot silently discard authored dependencies.
func hydrate_document(golden: Dictionary) -> Dictionary:
	var parsed := _parse_hydrated_document(golden)
	var error := str(parsed.get("error", ""))
	if not error.is_empty():
		return {"error": error}

	_clear_document_state()
	_rooms = parsed["rooms"]
	_occupancy = parsed["occupancy"]
	_portals = parsed["portals"]
	_verticals = parsed["verticals"]
	_props = parsed["props"]
	_hazards = parsed["hazards"]
	_next_id = int(parsed["next_room_id"])
	_next_prop_id = int(parsed["next_prop_id"])
	_next_hazard_serial = int(parsed["next_hazard_serial"])
	deck_count = int(parsed["deck_count"])
	active_deck = clampi(active_deck, 0, deck_count - 1)
	_refresh_document_visuals()
	occupancy_changed.emit()
	props_changed.emit()
	hazards_changed.emit()
	room_selected.emit({})
	return {"ok": true}


func _clear_document_state() -> void:
	_rooms.clear()
	_occupancy.clear()
	_portals.clear()
	_verticals.clear()
	_props.clear()
	_hazards.clear()
	_selected_id = 0
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	_selected_prop = -1
	_selected_hazard = -1
	_next_id = 1
	_next_prop_id = 1
	_next_hazard_serial = 1
	_armed_prop = {}
	_prop_ready = false
	_rotation_offset = 0
	_reserved.clear()
	_wall_slots.clear()
	_center_slots.clear()
	_solid_dirs.clear()
	_asset_sel = {}
	_has_pending = false
	_pending_cell = Vector3i.ZERO
	active_deck = 0
	deck_count = 1


func _refresh_document_visuals() -> void:
	if not is_node_ready():
		return
	_rebuild_grid()
	_sync_floors()
	_sync_links()
	_sync_hazards()
	_sync_slots()
	_sync_pending_anchor()
	_apply_camera()
	_refresh_ghost()
	pending_changed.emit(false, Vector3i.ZERO)
	deck_changed.emit(active_deck)


func _parse_hydrated_document(golden: Dictionary) -> Dictionary:
	var topology_v: Variant = golden.get("topology", {})
	if not (topology_v is Dictionary):
		return {"error": "topology must be an object"}
	var topology: Dictionary = topology_v
	var rooms_v: Variant = topology.get("rooms", [])
	if not (rooms_v is Array):
		return {"error": "topology.rooms must be an array"}

	var rooms: Array[Dictionary] = []
	var occupancy: Dictionary = {}
	var room_ids: Dictionary = {}
	var stable_ids: Dictionary = {}
	var max_room_id := 0
	var max_deck := 0
	for room_v in rooms_v:
		if not (room_v is Dictionary):
			return {"error": "topology.rooms entries must be objects"}
		var source: Dictionary = room_v
		var room_id := int(source.get("id", 0))
		var stable_id := str(source.get("stable_id", "")).strip_edges()
		var role := str(source.get("role", ""))
		var deck := int(source.get("deck", -1))
		if room_id <= 0 or room_ids.has(room_id):
			return {"error": "room id %d must be positive and unique" % room_id}
		if stable_id.is_empty() or stable_ids.has(stable_id):
			return {"error": "room stable_id '%s' must be non-empty and unique" % stable_id}
		if ROLES.find(role) < 0:
			return {"error": "room %d has unknown role '%s'" % [room_id, role]}
		if deck < 0 or deck >= MAX_DECKS:
			return {"error": "room %d deck %d is out of range" % [room_id, deck]}
		var cells_v: Variant = source.get("cells", [])
		if not (cells_v is Array) or (cells_v as Array).is_empty():
			return {"error": "room %d must contain at least one cell" % room_id}
		var cells: Array = []
		for cell_v in cells_v:
			if not (cell_v is Array) or (cell_v as Array).size() < 2:
				return {"error": "room %d contains a malformed cell" % room_id}
			var raw: Array = cell_v
			var xy := Vector2i(int(raw[0]), int(raw[1]))
			if not _in_aabb(xy.x, xy.y):
				return {"error": "room %d cell %s is outside the authoring bounds" % [room_id, xy]}
			var key := _key(Vector3i(xy.x, xy.y, deck))
			if occupancy.has(key):
				return {"error": "occupancy overlap at %s" % key}
			occupancy[key] = room_id
			cells.append(xy)
		rooms.append({
			"id": room_id,
			"stable_id": stable_id,
			"role": role,
			"deck": deck,
			"cells": cells,
		})
		room_ids[room_id] = true
		stable_ids[stable_id] = true
		max_room_id = maxi(max_room_id, room_id)
		max_deck = maxi(max_deck, deck)

	var portals_result := _parse_hydrated_links(topology.get("portals", []), room_ids, occupancy, false)
	if portals_result.has("error"):
		return portals_result
	var verticals_result := _parse_hydrated_links(topology.get("verticals", []), room_ids, occupancy, true)
	if verticals_result.has("error"):
		return verticals_result

	var props_v: Variant = golden.get("props", [])
	if not (props_v is Array):
		return {"error": "props must be an array"}
	var props: Array[Dictionary] = []
	var prop_ids: Dictionary = {}
	var max_prop_id := 0
	for prop_v in props_v:
		if not (prop_v is Dictionary):
			return {"error": "props entries must be objects"}
		var prop: Dictionary = (prop_v as Dictionary).duplicate(true)
		var prop_id := int(prop.get("id", 0))
		var prop_cell := _xyz_cell(prop.get("cell", []))
		if prop_id <= 0 or prop_ids.has(prop_id):
			return {"error": "prop id %d must be positive and unique" % prop_id}
		if not occupancy.has(_key(prop_cell)):
			return {"error": "prop %d is not on an occupied cell" % prop_id}
		if str(prop.get("kind", "")).to_lower() == "door":
			return {"error": "prop %d cannot use kind Door" % prop_id}
		props.append(prop)
		prop_ids[prop_id] = true
		max_prop_id = maxi(max_prop_id, prop_id)

	var hazards_result := _parse_hydrated_hazards(golden.get("hazards", {}), stable_ids, occupancy)
	if hazards_result.has("error"):
		return hazards_result
	return {
		"rooms": rooms,
		"occupancy": occupancy,
		"portals": portals_result["items"],
		"verticals": verticals_result["items"],
		"props": props,
		"hazards": hazards_result["items"],
		"next_room_id": max_room_id + 1,
		"next_prop_id": max_prop_id + 1,
		"next_hazard_serial": int(hazards_result["next_serial"]),
		"deck_count": clampi(max_deck + 1, 1, MAX_DECKS),
	}


func _parse_hydrated_links(value: Variant, room_ids: Dictionary, occupancy: Dictionary, vertical: bool) -> Dictionary:
	if not (value is Array):
		return {"error": "%s must be an array" % ("topology.verticals" if vertical else "topology.portals")}
	var items: Array[Dictionary] = []
	for item_v in value:
		if not (item_v is Dictionary):
			return {"error": "connection entries must be objects"}
		var item: Dictionary = (item_v as Dictionary).duplicate(true)
		var from_room := int(item.get("from_room", 0))
		var to_room := int(item.get("to_room", 0))
		var from_cell := _xyz_cell(item.get("from_cell", []))
		var to_cell := _xyz_cell(item.get("to_cell", []))
		var exterior := bool(item.get("exterior", false)) if not vertical else false
		if not room_ids.has(from_room) or (not exterior and not room_ids.has(to_room)):
			return {"error": "connection references an unknown room"}
		if int(occupancy.get(_key(from_cell), 0)) != from_room:
			return {"error": "connection from_cell does not belong to from_room"}
		if not exterior and int(occupancy.get(_key(to_cell), 0)) != to_room:
			return {"error": "connection to_cell does not belong to to_room"}
		if vertical:
			if from_cell.x != to_cell.x or from_cell.y != to_cell.y or absi(from_cell.z - to_cell.z) != 1:
				return {"error": "vertical endpoints must be stacked on adjacent decks"}
		else:
			var state := str(item.get("state", ""))
			if PORTAL_STATES.find(state) < 0:
				return {"error": "portal has invalid state '%s'" % state}
			if not exterior and not _is_cardinal(from_cell, to_cell):
				return {"error": "portal endpoints must be cardinal neighbors"}
		items.append(item)
	return {"items": items}


func _parse_hydrated_hazards(value: Variant, stable_ids: Dictionary, occupancy: Dictionary) -> Dictionary:
	if not (value is Dictionary):
		return {"error": "hazards must be an object"}
	var source: Dictionary = value
	var items: Array[Dictionary] = []
	var seen: Dictionary = {}
	var next_serial := 1
	for kind in HAZARD_KINDS:
		var bucket := str(HAZARD_BUCKET[kind])
		var bucket_v: Variant = source.get(bucket, [])
		if not (bucket_v is Array):
			return {"error": "hazards.%s must be an array" % bucket}
		for zone_v in bucket_v:
			if not (zone_v is Dictionary):
				return {"error": "hazard entries must be objects"}
			var zone: Dictionary = (zone_v as Dictionary).duplicate(true)
			var zone_id := str(zone.get("id", "")).strip_edges()
			var from_room := str(zone.get("from_room", ""))
			var to_room := str(zone.get("to_room", ""))
			var from_cell := _xyz_cell(zone.get("from_cell", []))
			var to_cell := _xyz_cell(zone.get("to_cell", []))
			if zone_id.is_empty() or seen.has(zone_id):
				return {"error": "hazard ids must be non-empty and unique"}
			if not stable_ids.has(from_room) or not stable_ids.has(to_room):
				return {"error": "hazard %s references an unknown room" % zone_id}
			if not occupancy.has(_key(from_cell)) or not occupancy.has(_key(to_cell)):
				return {"error": "hazard %s references an unoccupied cell" % zone_id}
			zone["kind"] = kind
			items.append(zone)
			seen[zone_id] = true
			var suffix := zone_id.get_slice("_", zone_id.get_slice_count("_") - 1)
			if suffix.is_valid_int():
				next_serial = maxi(next_serial, int(suffix) + 1)
	return {"items": items, "next_serial": next_serial}


func get_rooms() -> Array[Dictionary]:
	return _rooms


func get_selected() -> Dictionary:
	for r in _rooms:
		if int(r["id"]) == _selected_id:
			return r
	return {}


func get_portals() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in _portals:
		out.append(p.duplicate(true))
	return out


func get_verticals() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for v in _verticals:
		out.append(v.duplicate(true))
	return out


func get_selected_portal() -> Dictionary:
	if _selected_kind == "portal" and _selected_portal >= 0 and _selected_portal < _portals.size():
		return _portals[_selected_portal].duplicate(true)
	return {}


func get_selected_vertical() -> Dictionary:
	if _selected_kind == "vertical" and _selected_vertical >= 0 and _selected_vertical < _verticals.size():
		return _verticals[_selected_vertical].duplicate(true)
	return {}


func get_props() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in _props:
		out.append(_prop_dto(p))
	return out


func get_selected_prop() -> Dictionary:
	if _selected_kind == "prop" and _selected_prop >= 0 and _selected_prop < _props.size():
		return _prop_dto(_props[_selected_prop])
	return {}


func get_armed_prop() -> Dictionary:
	return _armed_prop.duplicate(true)


func get_hazards() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for h in _hazards:
		out.append(_hazard_dto(h))
	return out


func get_hazards_dto() -> Dictionary:
	var buckets := {
		"fire_zones": [],
		"breach_zones": [],
		"arc_zones": [],
		"radiation_zones": [],
	}
	for h in _hazards:
		var rec := _hazard_dto(h)
		var key := str(HAZARD_BUCKET.get(str(rec.get("kind", "")), ""))
		if key.is_empty() or not buckets.has(key):
			continue
		(buckets[key] as Array).append(rec)
	return {
		"source": "authored",
		"fire_zones": buckets["fire_zones"],
		"breach_zones": buckets["breach_zones"],
		"arc_zones": buckets["arc_zones"],
		"radiation_zones": buckets["radiation_zones"],
	}


func get_selected_hazard() -> Dictionary:
	if _selected_kind == "hazard" and _selected_hazard >= 0 and _selected_hazard < _hazards.size():
		return _hazard_dto(_hazards[_selected_hazard])
	return {}


func hazard_nodes() -> Array:
	if _hazard_root == null:
		return []
	return _hazard_root.get_children()


static func compartment_for_role(role: String) -> String:
	return str(COMPARTMENT_FOR_ROLE.get(role, ""))


static func hazard_kind_legal(kind: String) -> bool:
	return HAZARD_KINDS.find(kind) >= 0


func is_prop_ready() -> bool:
	return _prop_ready


func is_reserved_cell(cell: Vector3i) -> bool:
	return _reserved.has(_key(cell))


func is_wall_slot_cell(cell: Vector3i) -> bool:
	return _wall_slots.has(_key(cell))


func is_center_slot_cell(cell: Vector3i) -> bool:
	return _center_slots.has(_key(cell))


func get_asset_sel() -> Dictionary:
	if _selected_kind == "piece":
		return _asset_sel.duplicate(true)
	return {}


func has_vertical_at_key(key: String) -> bool:
	return _find_vertical_touching(_cell_from_key(key)) >= 0


func camera() -> Camera3D:
	return _camera


func to_viewport_point(pos: Vector2, viewport: SubViewport) -> Vector2:
	return _to_vp(pos, viewport)


func is_iso() -> bool:
	return _iso


func set_iso(iso: bool) -> void:
	_iso = iso
	if _iso:
		_yaw = ISO_YAW
		_pitch = ISO_PITCH
	_apply_camera()


func hide_ghost() -> void:
	_has_last_screen = false
	if _ghost:
		_ghost.visible = false
	_sync_pending_anchor()


## Hide occupancy CSG floors when kit GLBs cover the same cells. Paint, grid,
## ghost, and portal/vertical overlays stay active.
func set_occupancy_floors_visible(visible: bool) -> void:
	if _floors == null:
		return
	_floors.visible = visible


func occupancy_floors_visible() -> bool:
	return _floors != null and _floors.visible


func has_occupied(cell: Vector3i) -> bool:
	return _occupancy.has(_key(cell))


func paint_cell(cell: Vector3i) -> bool:
	return _try_paint(cell)


func is_painting() -> bool:
	return _lmb or _rmb


func cancel_pointer() -> void:
	_lmb = false
	_rmb = false
	_panning = false
	_orbiting = false
	_paint_drag = false
	_cancel_pending()
	_has_last_screen = false
	hide_ghost()


func has_pending_click() -> bool:
	return _has_pending


func pending_cell() -> Vector3i:
	return _pending_cell


## Arm a new room; the RoomSpec is created on the next successful void paint.
func create_room() -> void:
	_cancel_pending()
	_selected_id = 0
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	_selected_prop = -1
	_asset_sel = {}
	_selected_hazard = -1
	_sync_floors()
	_sync_links()
	room_selected.emit({})


## Re-applying the same tool still resets the pending click (plain buttons).
func set_tool(tool: String) -> void:
	if tool != TOOL_PAINT and tool != TOOL_PORTAL and tool != TOOL_VERTICAL and tool != TOOL_PROP and tool != TOOL_ASSET and tool != TOOL_HAZARD:
		return
	active_tool = tool
	_cancel_pending()
	_sync_slots()
	_refresh_ghost()
	tool_changed.emit(active_tool)


func arm_prop(entry: Dictionary) -> void:
	if str(entry.get("kind", "")) == "Door" or str(entry.get("kind", "")).to_lower() == "door":
		_armed_prop = {}
		return
	_armed_prop = entry.duplicate(true)
	_rotation_offset = 0
	_refresh_ghost()


func set_slot_overlay_visible(visible: bool) -> void:
	_show_slots = visible
	_sync_slots()


func set_compile_result(zones: Dictionary, plan: Dictionary, ok: bool) -> void:
	_prop_ready = ok
	_ingest_zones(zones)
	_ingest_solids(plan)
	_sync_slots()
	_refresh_ghost()


func try_place_prop(cell: Vector3i, hit: Vector3 = Vector3.ZERO) -> bool:
	if hit != Vector3.ZERO:
		_last_hit = hit
	return _try_lmb_prop(cell)


func stamp_portal_state(state: String) -> void:
	if PORTAL_STATES.find(state) < 0:
		return
	active_portal_state = state
	# Pending first-click is arming a new portal; do not restamp the last inspect.
	if _has_pending:
		return
	if _selected_kind != "portal" or _selected_portal < 0 or _selected_portal >= _portals.size():
		return
	var portal: Dictionary = _portals[_selected_portal]
	if str(portal["state"]) == state:
		return
	portal["state"] = state
	_sync_links()
	occupancy_changed.emit()
	portal_selected.emit(portal.duplicate(true))


func stamp_hazard_kind(kind: String) -> void:
	if not hazard_kind_legal(kind):
		return
	# Arm only. Re-click inspects without restamping an existing overlay;
	# a different kind on the same link is a second LinkZone.
	active_hazard_kind = kind


func apply_portal_edit(edited: Dictionary) -> void:
	if _selected_kind != "portal" or _selected_portal < 0 or _selected_portal >= _portals.size():
		return
	var state := str(edited.get("state", ""))
	if PORTAL_STATES.find(state) < 0:
		return
	var portal: Dictionary = _portals[_selected_portal]
	if str(portal["state"]) == state:
		return
	portal["state"] = state
	_sync_links()
	occupancy_changed.emit()
	portal_selected.emit(portal.duplicate(true))


func remove_selected_portal() -> void:
	if _selected_kind != "portal" or _selected_portal < 0 or _selected_portal >= _portals.size():
		return
	_portals.remove_at(_selected_portal)
	_selected_portal = -1
	_selected_kind = "room"
	var hz_pruned := _prune_hazards()
	_sync_links()
	occupancy_changed.emit()
	if hz_pruned:
		hazards_changed.emit()
	_emit_selection()


func remove_selected_vertical() -> void:
	if _selected_kind != "vertical" or _selected_vertical < 0 or _selected_vertical >= _verticals.size():
		return
	_verticals.remove_at(_selected_vertical)
	_selected_vertical = -1
	_selected_kind = "room"
	_sync_links()
	occupancy_changed.emit()
	_emit_selection()


func remove_selected_link() -> bool:
	if _selected_kind == "portal":
		remove_selected_portal()
		return true
	if _selected_kind == "vertical":
		remove_selected_vertical()
		return true
	if _selected_kind == "prop":
		remove_selected_prop()
		return true
	if _selected_kind == "hazard":
		remove_selected_hazard()
		return true
	return false


func remove_selected_hazard() -> void:
	if _selected_kind != "hazard" or _selected_hazard < 0 or _selected_hazard >= _hazards.size():
		return
	_hazards.remove_at(_selected_hazard)
	_selected_hazard = -1
	_selected_kind = "room"
	_sync_hazards()
	hazards_changed.emit()
	_emit_selection()


## Test/UI helper: one lattice click. Pending first click is not a DTO row.
func try_hazard_click(cell: Vector3i, hit: Vector3 = Vector3.ZERO) -> bool:
	if hit != Vector3.ZERO:
		_last_hit = hit
	var before := _hazards.size()
	var sel := _selected_hazard
	_try_lmb_hazard(cell)
	return _hazards.size() != before or (_selected_kind == "hazard" and _selected_hazard != sel)


## Test helper: commit a portal between two cells.
func try_place_portal(a: Vector3i, b: Vector3i) -> bool:
	_commit_portal(a, b)
	return _selected_kind == "portal"


## Test helper: commit a two-cell link. Re-click of the same kind inspects.
func try_place_hazard(a: Vector3i, b: Vector3i) -> bool:
	var before := _hazards.size()
	_commit_hazard(a, b)
	return _selected_kind == "hazard" and (_hazards.size() > before or _selected_hazard >= 0)


func apply_hazard_edit(edited: Dictionary) -> void:
	if _selected_kind != "hazard" or _selected_hazard < 0 or _selected_hazard >= _hazards.size():
		return
	var zone: Dictionary = _hazards[_selected_hazard]
	if edited.has("rationale"):
		zone["rationale"] = str(edited["rationale"])
	if edited.has("module_id"):
		zone["module_id"] = str(edited["module_id"])
	if edited.has("kind") and hazard_kind_legal(str(edited["kind"])):
		zone["kind"] = str(edited["kind"])
		active_hazard_kind = str(edited["kind"])
	_sync_hazards()
	hazards_changed.emit()
	hazard_selected.emit(_hazard_dto(zone))


func remove_selected_prop() -> void:
	if _selected_kind != "prop" or _selected_prop < 0 or _selected_prop >= _props.size():
		return
	_props.remove_at(_selected_prop)
	_selected_prop = -1
	_selected_kind = "room"
	props_changed.emit()
	_emit_selection()


func remove_prop_at(cell: Vector3i) -> bool:
	var idx := prop_index_at(cell)
	if idx < 0:
		return false
	var was_selected := _selected_kind == "prop" and _selected_prop == idx
	_props.remove_at(idx)
	if _selected_prop == idx:
		_selected_prop = -1
		_selected_kind = "room"
	elif _selected_prop > idx:
		_selected_prop -= 1
	props_changed.emit()
	if was_selected:
		_emit_selection()
	return true


func prop_index_at(cell: Vector3i) -> int:
	for i in _props.size():
		if _xyz_cell(_props[i].get("cell", [])) == cell:
			return i
	return -1


func cycle_prop_rotation(reverse: bool = false) -> bool:
	if _selected_kind == "prop" and _selected_prop >= 0 and _selected_prop < _props.size():
		var prop: Dictionary = _props[_selected_prop]
		prop["rotation"] = _PALETTE.next_rotation(prop, int(prop.get("rotation", 0)), reverse)
		props_changed.emit()
		prop_selected.emit(_prop_dto(prop))
		return true
	if active_tool == TOOL_PROP and not _armed_prop.is_empty():
		_rotation_offset = _PALETTE.next_rotation(_armed_prop, _rotation_offset, reverse)
		_refresh_ghost()
		return true
	return false


func apply_prop_edit(edited: Dictionary) -> void:
	if _selected_kind != "prop" or _selected_prop < 0 or _selected_prop >= _props.size():
		return
	var prop: Dictionary = _props[_selected_prop]
	if edited.has("locked"):
		prop["locked"] = bool(edited["locked"])
	if edited.has("rotation"):
		var rot := int(edited["rotation"])
		if rot >= 0 and rot <= 3:
			prop["rotation"] = _PALETTE.clamp_rotation(prop, rot)
	if edited.has("inventory_mode"):
		prop["inventory_mode"] = str(edited["inventory_mode"])
	if edited.has("inventory"):
		var inv: Array = []
		for s in edited.get("inventory", []):
			if s is Dictionary:
				inv.append({
					"item_id": str(s.get("item_id", "")),
					"qty": int(s.get("qty", 1)),
				})
		prop["inventory"] = inv
	if edited.has("loot_table"):
		var loot: Variant = edited["loot_table"]
		if loot == null or (loot is String and str(loot).is_empty()):
			prop["loot_table"] = null
		else:
			prop["loot_table"] = str(loot)
	props_changed.emit()
	prop_selected.emit(_prop_dto(prop))


func cancel_pending() -> void:
	if not _has_pending:
		return
	_cancel_pending()
	_refresh_ghost()
	hover_info.emit("pending click cancelled")


## Arm the occupancy brush. Does not rewrite rooms already painted, and does
## not deselect — touching same-role cells stay one room.
func arm_role(role: String) -> void:
	active_role = role


## Rewrite the selected room's role. Inspector and tests use this; the role
## palette does not — changing the brush must not recolor laid floors.
func stamp_role(role: String) -> void:
	active_role = role
	# Drop portal/vertical/prop/module/hazard selection so the inspector and
	# Delete/Backspace match the highlighted room.
	var converted := _selected_kind == "portal" or _selected_kind == "vertical" or _selected_kind == "prop" or _selected_kind == "piece" or _selected_kind == "hazard"
	if converted:
		_selected_kind = "room"
		_selected_portal = -1
		_selected_vertical = -1
		_selected_prop = -1
		_asset_sel = {}
		_selected_hazard = -1
	var room := get_selected()
	if room.is_empty():
		if converted:
			_sync_links()
			room_selected.emit({})
		return
	var changed := str(room["role"]) != role
	if not changed and not converted:
		return
	if changed:
		room["role"] = role
		_coalesce_touching_same_role()
		room = get_selected()
	var hz_changed := _refresh_hazard_rooms()
	_sync_floors()
	_sync_links()
	if changed:
		occupancy_changed.emit()
	if hz_changed:
		hazards_changed.emit()
	room_selected.emit(room)


func apply_room_edit(edited: Dictionary) -> void:
	var id := int(edited.get("id", 0))
	for r in _rooms:
		if int(r["id"]) != id:
			continue
		var sid := str(edited.get("stable_id", "")).strip_edges()
		if not sid.is_empty():
			r["stable_id"] = sid
		var role := str(edited.get("role", ""))
		if not role.is_empty():
			r["role"] = role
			_coalesce_touching_same_role()
			r = get_selected()
		var hz_changed := _refresh_hazard_rooms()
		_sync_floors()
		_sync_links()
		occupancy_changed.emit()
		if hz_changed:
			hazards_changed.emit()
		room_selected.emit(r)
		return


func select_room_id(id: int) -> void:
	_cancel_pending()
	_selected_id = id
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	_selected_prop = -1
	_asset_sel = {}
	_selected_hazard = -1
	_sync_floors()
	_sync_links()
	room_selected.emit(get_selected())


func nudge_deck(delta: int) -> void:
	if is_painting():
		return
	set_active_deck(active_deck + delta)


func add_deck() -> void:
	if is_painting() or deck_count >= MAX_DECKS:
		return
	deck_count += 1
	set_active_deck(deck_count - 1)


func set_active_deck(deck: int) -> void:
	var d := clampi(deck, 0, mini(MAX_DECKS - 1, deck_count - 1))
	if d == active_deck:
		return
	active_deck = d
	_rebuild_grid()
	_sync_floors()
	_sync_links()
	_sync_slots()
	_apply_camera()
	_refresh_ghost()
	deck_changed.emit(active_deck)


func handle_gui_input(event: InputEvent, viewport: SubViewport) -> void:
	var host := viewport.get_parent() as Control
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		var pos := (event as InputEventMouse).position
		_last_screen = _to_vp(pos, viewport)
		_has_last_screen = true
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_distance = clampf(_distance * 0.9, 8.0, 160.0)
			_apply_camera()
			_accept(host)
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_distance = clampf(_distance * 1.1, 8.0, 160.0)
			_apply_camera()
			_accept(host)
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			if _iso:
				_panning = mb.pressed
				_orbiting = false
			else:
				_orbiting = mb.pressed and not mb.shift_pressed
				_panning = mb.pressed and mb.shift_pressed
			_accept(host)
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_lmb = mb.pressed
			if not mb.pressed:
				_paint_drag = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_rmb = mb.pressed
		var cell := _pick_cell(_to_vp(mb.position, viewport))
		if not cell.get("ok", false):
			return
		var c: Vector3i = cell["cell"]
		_last_hit = cell.get("hit", Vector3.ZERO)
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_paint_drag = _try_lmb(c)
			_accept(host)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				if active_tool == TOOL_PROP:
					if not remove_prop_at(c):
						hover_info.emit("no prop on (%d,%d) deck %d" % [c.x, c.y, c.z])
				elif active_tool == TOOL_HAZARD:
					if not _erase_hazard_at(c):
						hover_info.emit("no hazard on (%d,%d) deck %d" % [c.x, c.y, c.z])
				elif active_tool == TOOL_ASSET:
					pass
				elif _has_pending and not _occupancy.has(_key(c)):
					cancel_pending()
				else:
					_erase_cell(c)
			_accept(host)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			_yaw -= mm.relative.x * 0.4
			_pitch = clampf(_pitch - mm.relative.y * 0.3, -85.0, -8.0)
			_apply_camera()
			_accept(host)
			return
		if _panning:
			_pan_camera(mm.relative)
			_accept(host)
			return
		var cell := _pick_cell(_to_vp(mm.position, viewport))
		if not cell.get("ok", false):
			hide_ghost()
			return
		var c: Vector3i = cell["cell"]
		_last_hit = cell.get("hit", Vector3.ZERO)
		_update_ghost(c)
		if _lmb and _paint_drag and active_tool == TOOL_PAINT:
			_try_paint(c)
		elif _rmb and active_tool != TOOL_PROP and active_tool != TOOL_ASSET and active_tool != TOOL_HAZARD:
			_erase_cell(c)


func _build_world() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.035, 0.04, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.46, 0.50, 0.58)
	env.ambient_light_energy = 0.85
	we.environment = env
	add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, 35, 0)
	key.light_energy = 1.15
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, -130, 0)
	fill.light_energy = 0.28
	add_child(fill)

	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)
	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.current = true
	_camera.near = 0.05
	_camera.far = 500.0
	_pivot.add_child(_camera)

	_floors = Node3D.new()
	_floors.name = "Floors"
	add_child(_floors)

	_links = Node3D.new()
	_links.name = "Links"
	add_child(_links)

	_hazard_root = Node3D.new()
	_hazard_root.name = "Hazards"
	add_child(_hazard_root)

	_slots = Node3D.new()
	_slots.name = "Slots"
	add_child(_slots)

	_grid = MeshInstance3D.new()
	_grid.name = "Grid"
	add_child(_grid)

	_ghost = MeshInstance3D.new()
	_ghost.name = "Ghost"
	var gmesh := BoxMesh.new()
	gmesh.size = Vector3(CELL_SIZE_M - 0.05, 0.16, CELL_SIZE_M - 0.05)
	_ghost.mesh = gmesh
	var gmat := StandardMaterial3D.new()
	gmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gmat.albedo_color = Color(0.45, 1.0, 0.5, 0.35)
	gmat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ghost.material_override = gmat
	_ghost.visible = false
	add_child(_ghost)

	_anchor = MeshInstance3D.new()
	_anchor.name = "PendingAnchor"
	var amesh := BoxMesh.new()
	amesh.size = Vector3(CELL_SIZE_M - 0.35, 0.22, CELL_SIZE_M - 0.35)
	_anchor.mesh = amesh
	var amat := StandardMaterial3D.new()
	amat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	amat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	amat.albedo_color = Color(0.25, 0.9, 1.0, 0.45)
	amat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_anchor.material_override = amat
	_anchor.visible = false
	add_child(_anchor)


func _apply_camera() -> void:
	if _camera == null:
		return
	_pivot.position = Vector3(_pan.x, active_deck * DECK_HEIGHT_M, _pan.z)
	_pivot.rotation_degrees = Vector3(_pitch, _yaw, 0.0)
	_camera.position = Vector3(0, 0, _distance)
	_camera.rotation = Vector3.ZERO
	if _iso:
		_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		_camera.size = _distance
	else:
		_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		_camera.fov = 50.0


func _pan_camera(relative: Vector2) -> void:
	var right := _camera.global_transform.basis.x
	right.y = 0.0
	if right.length_squared() < 0.0001:
		right = Vector3.RIGHT
	right = right.normalized()
	var fwd := _camera.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var sens := _distance * 0.004
	_pan += right * (-relative.x * sens) + fwd * (-relative.y * sens)
	_apply_camera()


func _accept(host: Control) -> void:
	if host:
		host.accept_event()


func _to_vp(pos: Vector2, viewport: SubViewport) -> Vector2:
	var parent := viewport.get_parent() as Control
	if parent == null or parent.size.x <= 0.0 or parent.size.y <= 0.0:
		return pos
	return pos * Vector2(viewport.size) / parent.size


func _pick_cell(screen: Vector2) -> Dictionary:
	if _camera == null:
		return {"ok": false}
	var from := _camera.project_ray_origin(screen)
	var dir := _camera.project_ray_normal(screen)
	if dir.length_squared() < 0.000001:
		return {"ok": false}
	var plane := Plane(Vector3.UP, active_deck * DECK_HEIGHT_M)
	var hit: Variant = plane.intersects_ray(from, dir)
	if hit == null:
		return {"ok": false}
	var p: Vector3 = hit
	# Cell::world_pos is the module center. Cell (x,y) occupies [x*4-2, x*4+2).
	var x := int(floor((p.x + CELL_SIZE_M * 0.5) / CELL_SIZE_M))
	var y := int(floor((p.z + CELL_SIZE_M * 0.5) / CELL_SIZE_M))
	return {"ok": true, "cell": Vector3i(x, y, active_deck), "hit": p}


func _try_lmb(cell: Vector3i) -> bool:
	match active_tool:
		TOOL_PORTAL:
			_try_lmb_portal(cell)
			return false
		TOOL_VERTICAL:
			_try_lmb_vertical(cell)
			return false
		TOOL_PROP:
			_try_lmb_prop(cell)
			return false
		TOOL_ASSET:
			_try_lmb_asset(cell)
			return false
		TOOL_HAZARD:
			_try_lmb_hazard(cell)
			return false
		_:
			return _try_lmb_paint(cell)


func _try_lmb_paint(cell: Vector3i) -> bool:
	var key := _key(cell)
	if _occupancy.has(key):
		# Occupied click inspects. Role changes for existing rooms go through
		# the inspector, not the armed brush.
		select_room_id(int(_occupancy[key]))
		return false
	return _try_paint(cell)


func _try_paint(cell: Vector3i) -> bool:
	var reason := _paint_block_reason(cell)
	if reason != "":
		hover_info.emit(reason)
		return false
	var room := _room_to_extend(cell)
	if room.is_empty():
		room = _make_room(active_role, cell.z)
		_rooms.append(room)
	if (room["cells"] as Array).is_empty():
		room["deck"] = cell.z
	(room["cells"] as Array).append(Vector2i(cell.x, cell.y))
	_occupancy[_key(cell)] = int(room["id"])
	_selected_id = int(room["id"])
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	_selected_prop = -1
	_asset_sel = {}
	_selected_hazard = -1
	_coalesce_touching_same_role()
	room = get_selected()
	_prune_links()
	var hz_pruned := _prune_hazards()
	_sync_deck_count()
	_sync_floors()
	_sync_links()
	occupancy_changed.emit()
	if hz_pruned:
		hazards_changed.emit()
	room_selected.emit(room)
	return true


func _erase_cell(cell: Vector3i) -> void:
	var key := _key(cell)
	if not _occupancy.has(key):
		return
	var id := int(_occupancy[key])
	_occupancy.erase(key)
	if _has_pending and _pending_cell == cell:
		_cancel_pending()
	var leftover: Array[Dictionary] = []
	for r in _rooms:
		if int(r["id"]) != id:
			leftover.append(r)
			continue
		var cells: Array = []
		for c in r["cells"]:
			var p: Vector2i = c
			if p.x == cell.x and p.y == cell.y:
				continue
			cells.append(p)
		if cells.is_empty():
			if _selected_id == id:
				_selected_id = 0
			continue
		var components := _connected_components(cells)
		r["cells"] = components[0]
		leftover.append(r)
		var deck := int(r["deck"])
		var role := str(r["role"])
		for i in range(1, components.size()):
			var split := _make_room(role, deck)
			split["cells"] = components[i]
			for p in components[i]:
				var xy: Vector2i = p
				_occupancy[_key(Vector3i(xy.x, xy.y, deck))] = int(split["id"])
			leftover.append(split)
	_rooms = leftover
	_prune_links()
	var pruned := _prune_props()
	var hz_pruned := _prune_hazards()
	_sync_floors()
	_sync_links()
	occupancy_changed.emit()
	if pruned:
		props_changed.emit()
	if hz_pruned:
		hazards_changed.emit()
	_emit_selection()


func _paint_block_reason(cell: Vector3i) -> String:
	if cell.z < 0 or cell.z >= MAX_DECKS:
		return "blocked: max 8 decks"
	if not _in_aabb(cell.x, cell.y):
		return "blocked: soft AABB 64×64"
	if _occupancy.has(_key(cell)):
		return "blocked: occupancy overlap"
	return ""


func _room_to_extend(cell: Vector3i) -> Dictionary:
	var xy := Vector2i(cell.x, cell.y)
	var selected := get_selected()
	if _room_accepts_cell(selected, cell.z, xy):
		return selected
	for r in _rooms:
		if _room_accepts_cell(r, cell.z, xy):
			return r
	return {}


func _rooms_share_cardinal(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	for c in b["cells"]:
		var p: Vector2i = c
		if _shares_cardinal(a, p):
			return true
	return false


func _merge_room_into(keep: Dictionary, drop: Dictionary) -> void:
	var kid := int(keep["id"])
	var did := int(drop["id"])
	var deck := int(keep["deck"])
	var cells: Array = keep["cells"]
	for c in drop["cells"]:
		var p: Vector2i = c
		cells.append(p)
		_occupancy[_key(Vector3i(p.x, p.y, deck))] = kid
	for p in _portals:
		if int(p.get("from_room", 0)) == did:
			p["from_room"] = kid
		if int(p.get("to_room", 0)) == did:
			p["to_room"] = kid
	for v in _verticals:
		if int(v.get("from_room", 0)) == did:
			v["from_room"] = kid
		if int(v.get("to_room", 0)) == did:
			v["to_room"] = kid
	if _selected_id == did:
		_selected_id = kid


func _coalesce_touching_same_role() -> void:
	var i := 0
	while i < _rooms.size():
		var room: Dictionary = _rooms[i]
		var absorbed := false
		var j := i + 1
		while j < _rooms.size():
			var other: Dictionary = _rooms[j]
			if str(other.get("role", "")) == str(room.get("role", "")) and int(other.get("deck", -1)) == int(room.get("deck", -2)) and _rooms_share_cardinal(room, other):
				_merge_room_into(room, other)
				_rooms.remove_at(j)
				absorbed = true
			else:
				j += 1
		if not absorbed:
			i += 1


func _room_accepts_cell(room: Dictionary, deck: int, xy: Vector2i) -> bool:
	if room.is_empty() or (room["cells"] as Array).is_empty():
		return false
	if str(room.get("role", "")) != active_role:
		return false
	if int(room.get("deck", -1)) != deck:
		return false
	return _shares_cardinal(room, xy)


func _shares_cardinal(room: Dictionary, cell: Vector2i) -> bool:
	for c in room["cells"]:
		var p: Vector2i = c
		for d in CARDINALS:
			if p + d == cell:
				return true
	return false


func _in_aabb(x: int, y: int) -> bool:
	return x >= AABB_MIN and x <= AABB_MAX and y >= AABB_MIN and y <= AABB_MAX


func _refresh_ghost() -> void:
	_sync_pending_anchor()
	if not _has_last_screen:
		if _ghost:
			_ghost.visible = false
		return
	var cell := _pick_cell(_last_screen)
	if cell.get("ok", false):
		_last_hit = cell.get("hit", Vector3.ZERO)
		_update_ghost(cell["cell"])
	else:
		if _ghost:
			_ghost.visible = false


func _connected_components(cells: Array) -> Array:
	var remaining: Dictionary = {}
	for c in cells:
		var p: Vector2i = c
		remaining[p] = true
	var out: Array = []
	while not remaining.is_empty():
		var start: Vector2i = remaining.keys()[0]
		var queue: Array[Vector2i] = [start]
		remaining.erase(start)
		var comp: Array = [start]
		while not queue.is_empty():
			var cur: Vector2i = queue.pop_front()
			for d in CARDINALS:
				var n: Vector2i = cur + d
				if remaining.has(n):
					remaining.erase(n)
					queue.append(n)
					comp.append(n)
		out.append(comp)
	return out


func _key(cell: Vector3i) -> String:
	return "%d|%d|%d" % [cell.z, cell.x, cell.y]


func _cell_from_key(key: String) -> Vector3i:
	var parts := key.split("|")
	if parts.size() != 3:
		return Vector3i.ZERO
	return Vector3i(int(parts[1]), int(parts[2]), int(parts[0]))


func _center(x: int, y: int, deck: int) -> Vector3:
	# Matches Cell::world_pos() / compiled kit pose (center, not min-corner).
	return Vector3(
		x * CELL_SIZE_M,
		deck * DECK_HEIGHT_M,
		y * CELL_SIZE_M
	)


func _make_room(role: String, deck: int) -> Dictionary:
	var id := _next_id
	_next_id += 1
	return {
		"id": id,
		"stable_id": _unique_stable(role, id),
		"role": role,
		"deck": deck,
		"cells": [],
	}


func _unique_stable(role: String, id: int) -> String:
	var base := "%s_%02d" % [role, id]
	var sid := base
	var n := 2
	while _stable_taken(sid):
		sid = "%s_%d" % [base, n]
		n += 1
	return sid


func _stable_taken(sid: String) -> bool:
	for r in _rooms:
		if str(r["stable_id"]) == sid:
			return true
	return false


func _sync_deck_count() -> void:
	var max_d := 0
	for r in _rooms:
		max_d = maxi(max_d, int(r["deck"]))
	deck_count = clampi(maxi(deck_count, max_d + 1), 1, MAX_DECKS)


func _update_ghost(cell: Vector3i) -> void:
	_sync_pending_anchor()
	match active_tool:
		TOOL_PORTAL:
			_update_portal_ghost(cell)
		TOOL_VERTICAL:
			_update_vertical_ghost(cell)
		TOOL_PROP:
			_update_prop_ghost(cell)
		TOOL_ASSET:
			_update_asset_ghost(cell)
		TOOL_HAZARD:
			_update_hazard_ghost(cell)
		_:
			_update_paint_ghost(cell)


func _update_paint_ghost(cell: Vector3i) -> void:
	var key := _key(cell)
	if _occupancy.has(key):
		_ghost.visible = false
		var id := int(_occupancy[key])
		var sid := ""
		for r in _rooms:
			if int(r["id"]) == id:
				sid = str(r["stable_id"])
				break
		hover_info.emit("select %s  (%d,%d deck %d)" % [sid, cell.x, cell.y, cell.z])
		return
	_place_cell_ghost(cell, _paint_block_reason(cell), "paint (%d,%d) deck %d" % [cell.x, cell.y, cell.z])


func _room_role(id: int) -> String:
	for r in _rooms:
		if int(r["id"]) == id:
			return str(r["role"])
	return ""


func _try_lmb_asset(cell: Vector3i) -> void:
	var sel := pick_compiled_at(cell, _last_hit)
	if sel.is_empty():
		_asset_sel = {}
		_selected_hazard = -1
		_selected_kind = "room"
		hover_info.emit("no compiled floor/wall/portal here")
		room_selected.emit({})
		return
	_apply_asset_sel(sel)


func pick_compiled_at(cell: Vector3i, hit: Vector3) -> Dictionary:
	var edge := _closest_pickable_edge(cell, hit)
	if not edge.is_empty():
		return edge
	if _occupancy.has(_key(cell)):
		return _floor_sel(cell)
	return {}


func _apply_asset_sel(sel: Dictionary) -> void:
	_asset_sel = sel.duplicate(true)
	_selected_kind = "piece"
	_selected_portal = int(sel.get("portal_index", -1))
	_selected_vertical = -1
	_selected_prop = -1
	_selected_hazard = -1
	if sel.get("ov_map", "") == "floors" or sel.get("ov_map", "") == "ceilings":
		var key := str(sel.get("key", ""))
		if _occupancy.has(key):
			_selected_id = int(_occupancy[key])
	elif _selected_portal >= 0 and _selected_portal < _portals.size():
		_selected_id = int(_portals[_selected_portal].get("from_room", 0))
	else:
		var a := _xyz_cell(sel.get("from_cell", []))
		var b := _xyz_cell(sel.get("to_cell", []))
		if _occupancy.has(_key(a)):
			_selected_id = int(_occupancy[_key(a)])
		elif _occupancy.has(_key(b)):
			_selected_id = int(_occupancy[_key(b)])
	_sync_floors()
	_sync_links()
	piece_selected.emit(_asset_sel.duplicate(true))


func _refresh_asset_sel(sel: Dictionary) -> Dictionary:
	if sel.is_empty():
		return {}
	var ov_map := str(sel.get("ov_map", ""))
	if ov_map == "floors" or ov_map == "ceilings":
		var key := str(sel.get("key", ""))
		if not _occupancy.has(key):
			return {}
		var cell := _cell_from_key(key)
		if ov_map == "ceilings":
			return _ceiling_sel(cell)
		return _floor_sel(cell)
	if ov_map == "edges":
		var a := _xyz_cell(sel.get("from_cell", []))
		var b := _xyz_cell(sel.get("to_cell", []))
		if a == Vector3i.ZERO and b == Vector3i.ZERO:
			return {}
		return _edge_sel(a, b)
	return {}


func _floor_sel(cell: Vector3i) -> Dictionary:
	var id := int(_occupancy.get(_key(cell), 0))
	return {
		"ov_map": "floors",
		"kind": "floor",
		"state": _room_role(id),
		"key": _key(cell),
		"cell": _cell_xyz(cell),
		"role": _room_role(id),
	}


func _ceiling_sel(cell: Vector3i) -> Dictionary:
	var id := int(_occupancy.get(_key(cell), 0))
	var suppressed := _find_vertical_touching(cell) >= 0
	return {
		"ov_map": "ceilings",
		"kind": "ceiling",
		"state": "",
		"key": _key(cell),
		"cell": _cell_xyz(cell),
		"role": _room_role(id),
		"note": "Ceiling is suppressed on this vertical opening." if suppressed else "",
	}


func _edge_sel(a: Vector3i, b: Vector3i) -> Dictionary:
	if not _is_cardinal(a, b):
		return {}
	var key := edge_key_between(a, b)
	var pidx := _find_portal(a, b)
	if pidx >= 0:
		var p: Dictionary = _portals[pidx]
		return {
			"ov_map": "edges",
			"kind": "portal",
			"state": str(p.get("state", "DOOR")),
			"key": key,
			"from_cell": p.get("from_cell", _cell_xyz(a)),
			"to_cell": p.get("to_cell", _cell_xyz(b)),
			"portal_index": pidx,
			"exterior": bool(p.get("exterior", false)),
		}
	if _edge_is_open(a, b):
		return {}
	var occupied := _occupancy.has(_key(a)) or _occupancy.has(_key(b))
	if not occupied:
		return {}
	return {
		"ov_map": "edges",
		"kind": "wall",
		"state": "SOLID",
		"key": key,
		"from_cell": _cell_xyz(a),
		"to_cell": _cell_xyz(b),
		"portal_index": -1,
	}


func _edge_is_open(a: Vector3i, b: Vector3i) -> bool:
	if not _occupancy.has(_key(a)) or not _occupancy.has(_key(b)):
		return false
	return int(_occupancy[_key(a)]) == int(_occupancy[_key(b)])


func edge_key_between(a: Vector3i, b: Vector3i) -> String:
	# plan.rs: N/S → deck|h|min(y,ny)|x ; E/W → deck|v|y|min(x,nx)
	if a.x == b.x:
		return "%d|h|%d|%d" % [a.z, mini(a.y, b.y), a.x]
	return "%d|v|%d|%d" % [a.z, a.y, mini(a.x, b.x)]


func _closest_pickable_edge(cell: Vector3i, hit: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d := 1.05
	for spec in _edge_bands(cell, hit):
		var d: float = spec["dist"]
		if d >= best_d:
			continue
		var n: Vector3i = spec["neighbor"]
		var sel := _edge_sel(cell, n)
		if sel.is_empty():
			continue
		best_d = d
		best = sel
	return best


func _edge_bands(cell: Vector3i, hit: Vector3) -> Array:
	var half := CELL_SIZE_M * 0.5
	var lx := hit.x - float(cell.x) * CELL_SIZE_M + half
	var lz := hit.z - float(cell.y) * CELL_SIZE_M + half
	return [
		{"dist": lx, "neighbor": Vector3i(cell.x - 1, cell.y, cell.z)},
		{"dist": CELL_SIZE_M - lx, "neighbor": Vector3i(cell.x + 1, cell.y, cell.z)},
		{"dist": lz, "neighbor": Vector3i(cell.x, cell.y - 1, cell.z)},
		{"dist": CELL_SIZE_M - lz, "neighbor": Vector3i(cell.x, cell.y + 1, cell.z)},
	]


func _update_asset_ghost(cell: Vector3i) -> void:
	var sel := pick_compiled_at(cell, _last_hit)
	if sel.is_empty():
		_ghost.visible = false
		hover_info.emit("assign module: click a compiled floor, wall, or portal")
		return
	var kind := str(sel.get("kind", ""))
	if kind == "floor" or kind == "ceiling":
		_place_cell_ghost(cell, "", "assign %s %s" % [kind, sel.get("key", "")])
		return
	var a := _xyz_cell(sel.get("from_cell", []))
	var b := _xyz_cell(sel.get("to_cell", []))
	_place_edge_ghost(a, b, "", "assign %s %s" % [kind, sel.get("key", "")])


func _color_for(room: Dictionary) -> Color:
	var role := str(room.get("role", "compartment"))
	var base: Color = ROLE_COLORS.get(role, Color(0.55, 0.58, 0.6))
	var h := fmod(float(int(room.get("id", 1))) * 0.17, 1.0)
	return base.lerp(Color.from_hsv(h, 0.45, 0.9), 0.12)


func _style_floor_box(box: CSGBox3D, room: Dictionary, deck: int) -> void:
	var col := _color_for(room)
	var mat := box.material as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		box.material = mat
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	var selected := int(room["id"]) == _selected_id
	mat.emission_enabled = selected
	if selected:
		mat.emission = col
		mat.emission_energy_multiplier = 0.4
	if deck != active_deck:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.16 if deck > active_deck else 0.34
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.albedo_color.a = 1.0


func _sync_floors() -> void:
	if _floors == null:
		return
	var wanted: Dictionary = {}
	for room in _rooms:
		var deck := int(room["deck"])
		for c in room["cells"]:
			var p: Vector2i = c
			wanted[_key(Vector3i(p.x, p.y, deck))] = room
	var stale: Array = []
	for key in _floor_boxes:
		if not wanted.has(key):
			stale.append(key)
	for key in stale:
		var old: CSGBox3D = _floor_boxes[key]
		_floors.remove_child(old)
		old.free()
		_floor_boxes.erase(key)
	for key in wanted:
		var room: Dictionary = wanted[key]
		var cell := _cell_from_key(str(key))
		var box: CSGBox3D
		if _floor_boxes.has(key):
			box = _floor_boxes[key]
		else:
			box = CSGBox3D.new()
			box.use_collision = false
			box.size = Vector3(CELL_SIZE_M - 0.1, 0.14, CELL_SIZE_M - 0.1)
			box.position = _center(cell.x, cell.y, cell.z)
			box.material = StandardMaterial3D.new()
			_floors.add_child(box)
			_floor_boxes[key] = box
		_style_floor_box(box, room, cell.z)


func _try_lmb_portal(cell: Vector3i) -> void:
	if _has_pending:
		if cell == _pending_cell:
			_cancel_pending()
			_refresh_ghost()
			hover_info.emit("portal cancelled")
			return
		var reason := _portal_block_reason(_pending_cell, cell)
		if reason == "":
			_commit_portal(_pending_cell, cell)
			_cancel_pending()
			_refresh_ghost()
			return
		if _occupancy.has(_key(cell)):
			_begin_pending(cell)
			hover_info.emit("portal from (%d,%d) deck %d — click cardinal neighbor" % [
				cell.x, cell.y, cell.z
			])
			return
		hover_info.emit(reason)
		return
	var near := _portal_index_near(cell, _last_hit)
	if near >= 0:
		_select_portal(near, true)
		return
	if not _occupancy.has(_key(cell)):
		hover_info.emit("blocked: portal start must be occupied")
		return
	_begin_pending(cell)
	hover_info.emit("portal from (%d,%d) deck %d — click cardinal neighbor" % [
		cell.x, cell.y, cell.z
	])


func _try_lmb_vertical(cell: Vector3i) -> void:
	if _has_pending:
		if cell == _pending_cell:
			_cancel_pending()
			_refresh_ghost()
			hover_info.emit("vertical cancelled")
			return
		var reason := _vertical_block_reason(_pending_cell, cell)
		if reason == "":
			_commit_vertical(_pending_cell, cell)
			_cancel_pending()
			_refresh_ghost()
			return
		if _occupancy.has(_key(cell)):
			_begin_pending(cell)
			hover_info.emit("vertical from (%d,%d) deck %d — click same (x,y) on deck ±1" % [
				cell.x, cell.y, cell.z
			])
			return
		hover_info.emit(reason)
		return
	if not _occupancy.has(_key(cell)):
		hover_info.emit("blocked: vertical start must be occupied")
		return
	# A stacked neighbor without a vertical can start a new shaft even when
	# this cell already participates in another opening.
	if not _has_unlinked_vertical_neighbor(cell):
		var existing := _find_vertical_touching(cell)
		if existing >= 0:
			_select_vertical(existing)
			return
	_begin_pending(cell)
	hover_info.emit("vertical from (%d,%d) deck %d — click same (x,y) on deck ±1" % [
		cell.x, cell.y, cell.z
	])


func _commit_portal(a: Vector3i, b: Vector3i) -> void:
	var existing := _find_portal(a, b)
	if existing >= 0:
		_select_portal(existing, true)
		return
	var from_room := int(_occupancy[_key(a)])
	var exterior := not _occupancy.has(_key(b))
	var to_room := 0 if exterior else int(_occupancy[_key(b)])
	_portals.append({
		"from_room": from_room,
		"to_room": to_room,
		"from_cell": _cell_xyz(a),
		"to_cell": _cell_xyz(b),
		"state": active_portal_state,
		"exterior": exterior,
	})
	_selected_kind = "portal"
	_selected_portal = _portals.size() - 1
	_selected_vertical = -1
	_selected_prop = -1
	_selected_hazard = -1
	_selected_id = from_room
	_sync_floors()
	_sync_links()
	occupancy_changed.emit()
	portal_selected.emit(_portals[_selected_portal].duplicate(true))


func _commit_vertical(a: Vector3i, b: Vector3i) -> void:
	var existing := _find_vertical(a, b)
	if existing >= 0:
		_select_vertical(existing)
		return
	var from_room := int(_occupancy[_key(a)])
	var to_room := int(_occupancy[_key(b)])
	_verticals.append({
		"from_room": from_room,
		"to_room": to_room,
		"from_cell": _cell_xyz(a),
		"to_cell": _cell_xyz(b),
	})
	_selected_kind = "vertical"
	_selected_vertical = _verticals.size() - 1
	_selected_portal = -1
	_selected_prop = -1
	_selected_hazard = -1
	_selected_id = from_room
	_sync_floors()
	_sync_links()
	occupancy_changed.emit()
	vertical_selected.emit(_verticals[_selected_vertical].duplicate(true))


## Stamp only when selecting a different portal so inspector state survives re-click.
func _select_portal(index: int, may_stamp: bool) -> void:
	if index < 0 or index >= _portals.size():
		return
	var stamped := false
	if may_stamp and index != _selected_portal:
		var portal: Dictionary = _portals[index]
		if str(portal["state"]) != active_portal_state:
			portal["state"] = active_portal_state
			stamped = true
	_selected_kind = "portal"
	_selected_portal = index
	_selected_vertical = -1
	_selected_prop = -1
	_selected_hazard = -1
	_selected_id = int(_portals[index]["from_room"])
	_sync_floors()
	_sync_links()
	if stamped:
		occupancy_changed.emit()
	portal_selected.emit(_portals[index].duplicate(true))


func _select_vertical(index: int) -> void:
	if index < 0 or index >= _verticals.size():
		return
	_selected_kind = "vertical"
	_selected_vertical = index
	_selected_portal = -1
	_selected_prop = -1
	_selected_hazard = -1
	_selected_id = int(_verticals[index]["from_room"])
	_sync_floors()
	_sync_links()
	vertical_selected.emit(_verticals[index].duplicate(true))


func _portal_block_reason(a: Vector3i, b: Vector3i) -> String:
	if a == b:
		return "blocked: portal endpoints must be distinct"
	if a.z != b.z:
		return "blocked: portal endpoints must be cardinal neighbors on the same deck"
	if not _is_cardinal(a, b):
		return "blocked: portal endpoints must be cardinal neighbors"
	if not _occupancy.has(_key(a)):
		return "blocked: portal start must be occupied"
	if _occupancy.has(_key(b)):
		if int(_occupancy[_key(a)]) == int(_occupancy[_key(b)]):
			return "blocked: portal connects room to itself"
	return ""


func _vertical_block_reason(a: Vector3i, b: Vector3i) -> String:
	if a == b:
		return "blocked: vertical endpoints must be stacked decks"
	if a.x != b.x or a.y != b.y:
		return "blocked: vertical must stack the same (x,y)"
	if absi(a.z - b.z) != 1:
		return "blocked: vertical must connect deck N to N±1"
	if not _occupancy.has(_key(a)) or not _occupancy.has(_key(b)):
		return "blocked: vertical opening requires both cells occupied"
	return ""


func _is_cardinal(a: Vector3i, b: Vector3i) -> bool:
	if a.z != b.z:
		return false
	var d := Vector2i(b.x - a.x, b.y - a.y)
	for c in CARDINALS:
		if c == d:
			return true
	return false


func _find_portal(a: Vector3i, b: Vector3i) -> int:
	for i in _portals.size():
		var fa := _xyz_cell(_portals[i]["from_cell"])
		var ta := _xyz_cell(_portals[i]["to_cell"])
		if (fa == a and ta == b) or (fa == b and ta == a):
			return i
	return -1


func _find_vertical(a: Vector3i, b: Vector3i) -> int:
	for i in _verticals.size():
		var fa := _xyz_cell(_verticals[i]["from_cell"])
		var ta := _xyz_cell(_verticals[i]["to_cell"])
		if (fa == a and ta == b) or (fa == b and ta == a):
			return i
	return -1


func _find_vertical_touching(cell: Vector3i) -> int:
	for i in _verticals.size():
		var fa := _xyz_cell(_verticals[i]["from_cell"])
		var ta := _xyz_cell(_verticals[i]["to_cell"])
		if fa == cell or ta == cell:
			return i
	return -1


func _has_unlinked_vertical_neighbor(cell: Vector3i) -> bool:
	for dz in [-1, 1]:
		var n := Vector3i(cell.x, cell.y, cell.z + dz)
		if n.z < 0 or n.z >= MAX_DECKS:
			continue
		if not _occupancy.has(_key(n)):
			continue
		if _find_vertical(cell, n) < 0:
			return true
	return false


func _portal_index_near(cell: Vector3i, hit: Vector3) -> int:
	var half := CELL_SIZE_M * 0.5
	var lx := hit.x - float(cell.x) * CELL_SIZE_M + half
	var lz := hit.z - float(cell.y) * CELL_SIZE_M + half
	var band := 1.05
	var dirs: Array[Vector2i] = []
	if lx < band:
		dirs.append(Vector2i(-1, 0))
	if lx > CELL_SIZE_M - band:
		dirs.append(Vector2i(1, 0))
	if lz < band:
		dirs.append(Vector2i(0, -1))
	if lz > CELL_SIZE_M - band:
		dirs.append(Vector2i(0, 1))
	for d in dirs:
		var n := Vector3i(cell.x + d.x, cell.y + d.y, cell.z)
		var idx := _find_portal(cell, n)
		if idx >= 0:
			return idx
	return -1


func _portal_valid(p: Dictionary) -> bool:
	var a := _xyz_cell(p.get("from_cell", []))
	var b := _xyz_cell(p.get("to_cell", []))
	if not _occupancy.has(_key(a)):
		return false
	if int(_occupancy[_key(a)]) != int(p.get("from_room", -1)):
		return false
	if bool(p.get("exterior", false)):
		return not _occupancy.has(_key(b)) and int(p.get("to_room", -1)) == 0
	if not _occupancy.has(_key(b)):
		return false
	if int(_occupancy[_key(a)]) == int(_occupancy[_key(b)]):
		return false
	return int(_occupancy[_key(b)]) == int(p.get("to_room", -1))


func _vertical_valid(v: Dictionary) -> bool:
	var a := _xyz_cell(v.get("from_cell", []))
	var b := _xyz_cell(v.get("to_cell", []))
	if _vertical_block_reason(a, b) != "":
		return false
	if int(_occupancy[_key(a)]) != int(v.get("from_room", -1)):
		return false
	return int(_occupancy[_key(b)]) == int(v.get("to_room", -1))


func _prune_links() -> void:
	var keep_p: Dictionary = {}
	if _selected_kind == "portal" and _selected_portal >= 0 and _selected_portal < _portals.size():
		keep_p = _portals[_selected_portal]
	var keep_v: Dictionary = {}
	if _selected_kind == "vertical" and _selected_vertical >= 0 and _selected_vertical < _verticals.size():
		keep_v = _verticals[_selected_vertical]
	var next_p: Array[Dictionary] = []
	for p in _portals:
		if _portal_valid(p):
			next_p.append(p)
	_portals = next_p
	var next_v: Array[Dictionary] = []
	for v in _verticals:
		if _vertical_valid(v):
			next_v.append(v)
	_verticals = next_v
	_selected_portal = -1
	_selected_vertical = -1
	if _selected_kind == "portal":
		for i in _portals.size():
			if _same_endpoints(_portals[i], keep_p):
				_selected_portal = i
				break
		if _selected_portal < 0:
			_selected_kind = "room"
	elif _selected_kind == "vertical":
		for i in _verticals.size():
			if _same_endpoints(_verticals[i], keep_v):
				_selected_vertical = i
				break
		if _selected_vertical < 0:
			_selected_kind = "room"


func _same_endpoints(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	var af := _xyz_cell(a.get("from_cell", []))
	var at := _xyz_cell(a.get("to_cell", []))
	var bf := _xyz_cell(b.get("from_cell", []))
	var bt := _xyz_cell(b.get("to_cell", []))
	return (af == bf and at == bt) or (af == bt and at == bf)


func _emit_selection() -> void:
	if _selected_kind == "portal" and _selected_portal >= 0 and _selected_portal < _portals.size():
		portal_selected.emit(_portals[_selected_portal].duplicate(true))
		return
	if _selected_kind == "vertical" and _selected_vertical >= 0 and _selected_vertical < _verticals.size():
		vertical_selected.emit(_verticals[_selected_vertical].duplicate(true))
		return
	if _selected_kind == "prop" and _selected_prop >= 0 and _selected_prop < _props.size():
		prop_selected.emit(_prop_dto(_props[_selected_prop]))
		return
	if _selected_kind == "piece":
		_asset_sel = _refresh_asset_sel(_asset_sel)
		if not _asset_sel.is_empty():
			piece_selected.emit(_asset_sel.duplicate(true))
			return
	if _selected_kind == "hazard" and _selected_hazard >= 0 and _selected_hazard < _hazards.size():
		hazard_selected.emit(_hazard_dto(_hazards[_selected_hazard]))
		return
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	_selected_prop = -1
	_asset_sel = {}
	_selected_hazard = -1
	room_selected.emit(get_selected())


func _cancel_pending() -> void:
	_has_pending = false
	_pending_cell = Vector3i.ZERO
	_sync_pending_anchor()
	pending_changed.emit(false, _pending_cell)


## First click of a two-click tool. Drops portal/vertical/hazard inspect so the
## state palette cannot restamp the previous selection.
func _begin_pending(cell: Vector3i) -> void:
	_has_pending = true
	_pending_cell = cell
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	_selected_prop = -1
	_asset_sel = {}
	_selected_hazard = -1
	if _occupancy.has(_key(cell)):
		_selected_id = int(_occupancy[_key(cell)])
	_sync_pending_anchor()
	_sync_floors()
	_sync_links()
	pending_changed.emit(true, _pending_cell)
	room_selected.emit(get_selected())


func focus_diagnostic(cell: Vector3i, target_type: String = "") -> void:
	set_active_deck(cell.z)
	if target_type == "connection":
		for index in range(_portals.size()):
			var portal: Dictionary = _portals[index]
			if _xyz_cell(portal.get("from_cell", [])) == cell or _xyz_cell(portal.get("to_cell", [])) == cell:
				_select_portal(index, false)
				return
		for index in range(_verticals.size()):
			var vertical: Dictionary = _verticals[index]
			if _xyz_cell(vertical.get("from_cell", [])) == cell or _xyz_cell(vertical.get("to_cell", [])) == cell:
				_select_vertical(index)
				return
	elif target_type == "prop":
		for index in range(_props.size()):
			if _xyz_cell((_props[index] as Dictionary).get("cell", [])) == cell:
				_select_prop(index)
				return
	elif target_type == "hazard":
		for index in range(_hazards.size()):
			var hazard: Dictionary = _hazards[index]
			if _xyz_cell(hazard.get("from_cell", [])) == cell or _xyz_cell(hazard.get("to_cell", [])) == cell:
				_select_hazard(index, false)
				return
	var key := _key(cell)
	if _occupancy.has(key):
		select_room_id(int(_occupancy[key]))


func _sync_pending_anchor() -> void:
	if _anchor == null:
		return
	_anchor.visible = _has_pending
	if _has_pending:
		_anchor.position = _center(_pending_cell.x, _pending_cell.y, _pending_cell.z) + Vector3(0, 0.12, 0)


func _place_cell_ghost(cell: Vector3i, reason: String, ok_text: String) -> void:
	_ghost.visible = true
	_ghost.position = _center(cell.x, cell.y, cell.z)
	_ghost.rotation_degrees = Vector3.ZERO
	var gmesh := _ghost.mesh as BoxMesh
	if gmesh:
		gmesh.size = Vector3(CELL_SIZE_M - 0.05, 0.16, CELL_SIZE_M - 0.05)
	var mat := _ghost.material_override as StandardMaterial3D
	if reason == "":
		mat.albedo_color = Color(0.45, 1.0, 0.5, 0.35)
		hover_info.emit(ok_text)
	else:
		mat.albedo_color = Color(1.0, 0.28, 0.22, 0.4)
		hover_info.emit(reason)


func _place_edge_ghost(a: Vector3i, b: Vector3i, reason: String, ok_text: String) -> void:
	_ghost.visible = true
	_ghost.rotation_degrees = Vector3.ZERO
	var pa := _center(a.x, a.y, a.z)
	var pb := _center(b.x, b.y, b.z)
	_ghost.position = (pa + pb) * 0.5 + Vector3(0, 0.7, 0)
	var gmesh := _ghost.mesh as BoxMesh
	if gmesh:
		if a.x != b.x:
			gmesh.size = Vector3(0.55, 1.6, CELL_SIZE_M - 0.45)
		else:
			gmesh.size = Vector3(CELL_SIZE_M - 0.45, 1.6, 0.55)
	var mat := _ghost.material_override as StandardMaterial3D
	if reason == "":
		mat.albedo_color = Color(0.3, 0.95, 1.0, 0.4)
		hover_info.emit(ok_text)
	else:
		mat.albedo_color = Color(1.0, 0.28, 0.22, 0.45)
		hover_info.emit(reason)


func _update_portal_ghost(cell: Vector3i) -> void:
	if _has_pending:
		if cell == _pending_cell:
			_place_cell_ghost(cell, "", "click again to cancel portal")
			return
		var reason := _portal_block_reason(_pending_cell, cell)
		if _is_cardinal(_pending_cell, cell):
			var ok := "portal %s (%d,%d) → (%d,%d)" % [
				active_portal_state, _pending_cell.x, _pending_cell.y, cell.x, cell.y
			]
			if reason == "" and not _occupancy.has(_key(cell)):
				ok = "exterior %s (%d,%d) → void (%d,%d)" % [
					active_portal_state, _pending_cell.x, _pending_cell.y, cell.x, cell.y
				]
			if reason == "" and _find_portal(_pending_cell, cell) >= 0:
				ok = "select existing portal"
			_place_edge_ghost(_pending_cell, cell, reason, ok)
			return
		_place_cell_ghost(cell, reason if reason != "" else "blocked: portal endpoints must be cardinal neighbors", "")
		return
	var near := _portal_index_near(cell, _last_hit)
	if near >= 0:
		_ghost.visible = false
		hover_info.emit("select portal %s" % str(_portals[near].get("state", "DOOR")))
		return
	if _occupancy.has(_key(cell)):
		_place_cell_ghost(cell, "", "portal from (%d,%d) deck %d" % [cell.x, cell.y, cell.z])
		return
	_place_cell_ghost(cell, "blocked: portal start must be occupied", "")


func _update_vertical_ghost(cell: Vector3i) -> void:
	if _has_pending:
		if cell == _pending_cell:
			_place_cell_ghost(cell, "", "click again to cancel vertical")
			return
		var reason := _vertical_block_reason(_pending_cell, cell)
		var ok := "vertical (%d,%d deck %d) ↔ (%d,%d deck %d)" % [
			_pending_cell.x, _pending_cell.y, _pending_cell.z, cell.x, cell.y, cell.z
		]
		if reason == "" and _find_vertical(_pending_cell, cell) >= 0:
			ok = "select existing vertical"
		_place_cell_ghost(cell, reason, ok)
		return
	if not _occupancy.has(_key(cell)):
		_place_cell_ghost(cell, "blocked: vertical start must be occupied", "")
		return
	if not _has_unlinked_vertical_neighbor(cell):
		var existing := _find_vertical_touching(cell)
		if existing >= 0:
			_ghost.visible = false
			hover_info.emit("select vertical opening")
			return
	_place_cell_ghost(cell, "", "vertical from (%d,%d) deck %d — click N±1" % [cell.x, cell.y, cell.z])


func _try_lmb_hazard(cell: Vector3i) -> void:
	if _has_pending:
		if cell == _pending_cell:
			_cancel_pending()
			_refresh_ghost()
			hover_info.emit("hazard cancelled")
			return
		var reason := _hazard_block_reason(_pending_cell, cell)
		if reason == "":
			_commit_hazard(_pending_cell, cell)
			_cancel_pending()
			_refresh_ghost()
			return
		if _occupancy.has(_key(cell)):
			_begin_pending(cell)
			hover_info.emit("%s from (%d,%d) deck %d — click cardinal neighbor or portal edge" % [
				active_hazard_kind, cell.x, cell.y, cell.z
			])
			return
		hover_info.emit(reason)
		return
	var portal_idx := _portal_index_near(cell, _last_hit)
	if portal_idx >= 0:
		_commit_hazard_from_portal(portal_idx)
		return
	var existing := _hazard_index_near(cell, _last_hit)
	if existing >= 0:
		var hz: Dictionary = _hazards[existing]
		if str(hz.get("kind", "")) == active_hazard_kind:
			_select_hazard(existing, false)
			return
		# Different kind on this link: second overlay, same endpoints as portal path.
		_commit_hazard(_xyz_cell(hz["from_cell"]), _xyz_cell(hz["to_cell"]))
		return
	if not _occupancy.has(_key(cell)):
		hover_info.emit("blocked: hazard start must be occupied")
		return
	_begin_pending(cell)
	hover_info.emit("%s from (%d,%d) deck %d — click cardinal neighbor or portal edge" % [
		active_hazard_kind, cell.x, cell.y, cell.z
	])


func _commit_hazard(a: Vector3i, b: Vector3i) -> void:
	var portal_idx := _find_portal(a, b)
	if portal_idx >= 0:
		_commit_hazard_from_portal(portal_idx)
		return
	var stored_from := a
	var stored_to := b
	if a != b:
		var reason := _hazard_block_reason(a, b)
		if reason != "":
			hover_info.emit(reason)
			return
		if not _occupancy.has(_key(b)):
			# Same-room visual: duplicate from_cell so the loader does not resolve a void.
			stored_to = a
	else:
		# Collapsed stored pair from a prior void-neighbor commit.
		if not _occupancy.has(_key(a)):
			hover_info.emit("blocked: hazard start must be occupied")
			return
	var existing := _find_hazard(stored_from, stored_to, active_hazard_kind)
	if existing >= 0:
		_select_hazard(existing, false)
		return
	if not _occupancy.has(_key(stored_from)):
		hover_info.emit("blocked: hazard start must be occupied")
		return
	var from_id := int(_occupancy[_key(stored_from)])
	var from_stable := _stable_of(from_id)
	var to_stable := from_stable
	if stored_from != stored_to and _occupancy.has(_key(stored_to)):
		to_stable = _stable_of(int(_occupancy[_key(stored_to)]))
	_append_hazard({
		"id": _next_hazard_id(active_hazard_kind),
		"from_room": from_stable,
		"to_room": to_stable,
		"from_cell": _cell_xyz(stored_from),
		"to_cell": _cell_xyz(stored_to),
		"module_id": "",
		"kind": active_hazard_kind,
		"compartment_id": _compartment_for_link(from_id, stored_to),
		"rationale": "",
	})


func _commit_hazard_from_portal(index: int) -> void:
	if index < 0 or index >= _portals.size():
		return
	var p: Dictionary = _portals[index]
	var a := _xyz_cell(p.get("from_cell", []))
	var b := _xyz_cell(p.get("to_cell", []))
	var existing := _find_hazard(a, b, active_hazard_kind)
	if existing >= 0:
		_select_hazard(existing, false)
		return
	var from_id := int(p.get("from_room", 0))
	var from_stable := _stable_of(from_id)
	var to_stable := from_stable
	if not bool(p.get("exterior", false)) and int(p.get("to_room", 0)) != 0:
		to_stable = _stable_of(int(p.get("to_room", 0)))
	_append_hazard({
		"id": _next_hazard_id(active_hazard_kind),
		"from_room": from_stable,
		"to_room": to_stable,
		"from_cell": _cell_xyz(a),
		"to_cell": _cell_xyz(b),
		"module_id": "",
		"kind": active_hazard_kind,
		"compartment_id": _compartment_for_link(from_id, b),
		"rationale": "",
	})


func _append_hazard(zone: Dictionary) -> void:
	# Never persist an incomplete overlay. Callers only commit both endpoints.
	if str(zone.get("id", "")).is_empty() or str(zone.get("kind", "")).is_empty():
		return
	if str(zone.get("from_room", "")).is_empty():
		return
	var from_cell: Variant = zone.get("from_cell", [])
	var to_cell: Variant = zone.get("to_cell", [])
	if not (from_cell is Array) or (from_cell as Array).size() < 3:
		return
	if not (to_cell is Array) or (to_cell as Array).size() < 3:
		return
	_hazards.append(zone)
	_selected_kind = "hazard"
	_selected_hazard = _hazards.size() - 1
	_selected_portal = -1
	_selected_vertical = -1
	_selected_prop = -1
	_asset_sel = {}
	if _occupancy.has(_key(_xyz_cell(from_cell))):
		_selected_id = int(_occupancy[_key(_xyz_cell(from_cell))])
	_sync_floors()
	_sync_links()
	hazards_changed.emit()
	hazard_selected.emit(_hazard_dto(zone))


## Stamp kind only when selecting a *different* zone so re-click inspects.
func _select_hazard(index: int, may_stamp: bool) -> void:
	if index < 0 or index >= _hazards.size():
		return
	var stamped := false
	if may_stamp and index != _selected_hazard:
		var zone: Dictionary = _hazards[index]
		if str(zone["kind"]) != active_hazard_kind:
			zone["kind"] = active_hazard_kind
			stamped = true
	_selected_kind = "hazard"
	_selected_hazard = index
	_selected_portal = -1
	_selected_vertical = -1
	_selected_prop = -1
	_asset_sel = {}
	var from_cell := _xyz_cell(_hazards[index].get("from_cell", []))
	if _occupancy.has(_key(from_cell)):
		_selected_id = int(_occupancy[_key(from_cell)])
	_sync_floors()
	_sync_links()
	if stamped:
		hazards_changed.emit()
	hazard_selected.emit(_hazard_dto(_hazards[index]))


func _hazard_block_reason(a: Vector3i, b: Vector3i) -> String:
	if a == b:
		return "blocked: hazard endpoints must be distinct"
	if a.z != b.z:
		return "blocked: hazard endpoints must be cardinal neighbors on the same deck"
	if not _is_cardinal(a, b):
		return "blocked: hazard endpoints must be cardinal neighbors"
	if not _occupancy.has(_key(a)):
		return "blocked: hazard start must be occupied"
	return ""


func _find_hazard(a: Vector3i, b: Vector3i, kind: String = "") -> int:
	for i in _hazards.size():
		var fa := _xyz_cell(_hazards[i]["from_cell"])
		var ta := _xyz_cell(_hazards[i]["to_cell"])
		if kind != "" and str(_hazards[i]["kind"]) != kind:
			continue
		if (fa == a and ta == b) or (fa == b and ta == a):
			return i
	# Void-neighbor commits store (a,a). Occupied a + void b of the same kind
	# must inspect that collapsed pair, not append a duplicate.
	if a != b and _occupancy.has(_key(a)) and not _occupancy.has(_key(b)):
		for i in _hazards.size():
			var fa2 := _xyz_cell(_hazards[i]["from_cell"])
			var ta2 := _xyz_cell(_hazards[i]["to_cell"])
			if kind != "" and str(_hazards[i]["kind"]) != kind:
				continue
			if fa2 == a and ta2 == a:
				return i
	if b != a and _occupancy.has(_key(b)) and not _occupancy.has(_key(a)):
		for i in _hazards.size():
			var fa3 := _xyz_cell(_hazards[i]["from_cell"])
			var ta3 := _xyz_cell(_hazards[i]["to_cell"])
			if kind != "" and str(_hazards[i]["kind"]) != kind:
				continue
			if fa3 == b and ta3 == b:
				return i
	return -1


func _hazard_index_near(cell: Vector3i, hit: Vector3) -> int:
	var portal_like := _portal_index_near(cell, hit)
	if portal_like >= 0:
		var p: Dictionary = _portals[portal_like]
		var idx := _find_hazard(_xyz_cell(p["from_cell"]), _xyz_cell(p["to_cell"]), active_hazard_kind)
		if idx >= 0:
			return idx
		idx = _find_hazard(_xyz_cell(p["from_cell"]), _xyz_cell(p["to_cell"]), "")
		if idx >= 0:
			return idx
	var kind_hit := -1
	var any_hit := -1
	for i in _hazards.size():
		var fa := _xyz_cell(_hazards[i]["from_cell"])
		var ta := _xyz_cell(_hazards[i]["to_cell"])
		if fa != cell and ta != cell:
			continue
		var other := ta if fa == cell else fa
		if fa == ta:
			if str(_hazards[i]["kind"]) == active_hazard_kind:
				return i
			if any_hit < 0:
				any_hit = i
			continue
		if _is_cardinal(cell, other):
			var band := _hit_dir(cell, hit)
			var want := _dir_between(cell, other)
			if band == "" or band == want:
				if str(_hazards[i]["kind"]) == active_hazard_kind:
					kind_hit = i
				elif any_hit < 0:
					any_hit = i
		elif fa == cell or ta == cell:
			if str(_hazards[i]["kind"]) == active_hazard_kind and kind_hit < 0:
				kind_hit = i
			elif any_hit < 0:
				any_hit = i
	if kind_hit >= 0:
		return kind_hit
	return any_hit


func _dir_between(a: Vector3i, b: Vector3i) -> String:
	var d := Vector2i(b.x - a.x, b.y - a.y)
	if d == Vector2i(1, 0):
		return "east"
	if d == Vector2i(-1, 0):
		return "west"
	if d == Vector2i(0, 1):
		return "south"
	if d == Vector2i(0, -1):
		return "north"
	return ""


func _erase_hazard_at(cell: Vector3i) -> bool:
	var idx := _hazard_index_near(cell, _last_hit)
	if idx < 0:
		# Fallback: any zone touching the cell.
		for i in _hazards.size():
			var fa := _xyz_cell(_hazards[i]["from_cell"])
			var ta := _xyz_cell(_hazards[i]["to_cell"])
			if fa == cell or ta == cell:
				idx = i
				break
	if idx < 0:
		return false
	var was_selected := _selected_kind == "hazard" and _selected_hazard == idx
	_hazards.remove_at(idx)
	if _selected_hazard == idx:
		_selected_hazard = -1
		_selected_kind = "room"
	elif _selected_hazard > idx:
		_selected_hazard -= 1
	_sync_hazards()
	hazards_changed.emit()
	if was_selected:
		_emit_selection()
	return true


func _hazard_valid(h: Dictionary) -> bool:
	var a := _xyz_cell(h.get("from_cell", []))
	var b := _xyz_cell(h.get("to_cell", []))
	if not _occupancy.has(_key(a)):
		return false
	if str(h.get("from_room", "")) != _stable_of(int(_occupancy[_key(a)])):
		return false
	if a == b:
		return str(h.get("to_room", "")) == str(h.get("from_room", ""))
	if _occupancy.has(_key(b)):
		return str(h.get("to_room", "")) == _stable_of(int(_occupancy[_key(b)]))
	# Void to_cell is legal only while the matching exterior portal exists.
	var portal_idx := _find_portal(a, b)
	if portal_idx < 0:
		return false
	return bool(_portals[portal_idx].get("exterior", false))


func _prune_hazards() -> bool:
	var keep: Dictionary = {}
	if _selected_kind == "hazard" and _selected_hazard >= 0 and _selected_hazard < _hazards.size():
		keep = _hazards[_selected_hazard]
	var next: Array[Dictionary] = []
	var changed := false
	for h in _hazards:
		if _hazard_valid(h):
			next.append(h)
		else:
			changed = true
	if not changed and next.size() == _hazards.size():
		_refresh_hazard_rooms()
		_sync_hazards()
		return false
	_hazards = next
	_selected_hazard = -1
	if _selected_kind == "hazard":
		for i in _hazards.size():
			if _same_endpoints(_hazards[i], keep) and str(_hazards[i].get("kind", "")) == str(keep.get("kind", "")):
				_selected_hazard = i
				break
		if _selected_hazard < 0:
			_selected_kind = "room"
	_refresh_hazard_rooms()
	_sync_hazards()
	return changed


func _refresh_hazard_rooms() -> bool:
	var changed := false
	for h in _hazards:
		var a := _xyz_cell(h.get("from_cell", []))
		var b := _xyz_cell(h.get("to_cell", []))
		if not _occupancy.has(_key(a)):
			continue
		var from_id := int(_occupancy[_key(a)])
		var from_sid := _stable_of(from_id)
		var to_sid := from_sid
		if _occupancy.has(_key(b)):
			to_sid = _stable_of(int(_occupancy[_key(b)]))
		var cid := _compartment_for_link(from_id, b)
		if str(h.get("from_room", "")) != from_sid or str(h.get("to_room", "")) != to_sid or str(h.get("compartment_id", "")) != cid:
			changed = true
		h["from_room"] = from_sid
		h["to_room"] = to_sid
		h["compartment_id"] = cid
	return changed


func _compartment_for_link(from_id: int, to_cell: Vector3i) -> String:
	var cid := compartment_for_role(_room_role(from_id))
	if cid != "":
		return cid
	if _occupancy.has(_key(to_cell)):
		return compartment_for_role(_room_role(int(_occupancy[_key(to_cell)])))
	return ""


func _stable_of(id: int) -> String:
	for r in _rooms:
		if int(r["id"]) == id:
			return str(r["stable_id"])
	return ""


func _next_hazard_id(kind: String) -> String:
	var n := _next_hazard_serial
	var hid := "%s_%02d" % [kind, n]
	n += 1
	while _hazard_id_taken(hid):
		hid = "%s_%02d" % [kind, n]
		n += 1
	_next_hazard_serial = n
	return hid


func _hazard_id_taken(hid: String) -> bool:
	for h in _hazards:
		if str(h.get("id", "")) == hid:
			return true
	return false


func _hazard_dto(zone: Dictionary) -> Dictionary:
	var from_cell: Variant = zone.get("from_cell", [0, 0, 0])
	var to_cell: Variant = zone.get("to_cell", [0, 0, 0])
	return {
		"id": str(zone.get("id", "")),
		"from_room": str(zone.get("from_room", "")),
		"to_room": str(zone.get("to_room", "")),
		"from_cell": from_cell,
		"to_cell": to_cell,
		"module_id": str(zone.get("module_id", "")),
		"kind": str(zone.get("kind", "")),
		"compartment_id": str(zone.get("compartment_id", "")),
		"rationale": str(zone.get("rationale", "")),
	}


func _sync_hazards() -> void:
	if _hazard_root == null:
		return
	var wanted: Dictionary = {}
	for i in _hazards.size():
		var h: Dictionary = _hazards[i]
		var k := "%s:%s" % [str(h.get("kind", "")), _undirected_key(_xyz_cell(h["from_cell"]), _xyz_cell(h["to_cell"]))]
		wanted[k] = i
	var stale: Array = []
	for key in _hazard_boxes:
		if not wanted.has(key):
			stale.append(key)
	for key in stale:
		var old: CSGBox3D = _hazard_boxes[key]
		_hazard_root.remove_child(old)
		old.free()
		_hazard_boxes.erase(key)
	for key in wanted:
		var idx: int = wanted[key]
		var zone: Dictionary = _hazards[idx]
		var box: CSGBox3D
		if _hazard_boxes.has(key):
			box = _hazard_boxes[key]
		else:
			box = CSGBox3D.new()
			box.use_collision = false
			box.material = StandardMaterial3D.new()
			_hazard_root.add_child(box)
			_hazard_boxes[key] = box
		_style_hazard_box(box, zone, idx == _selected_hazard and _selected_kind == "hazard")


func _style_hazard_box(box: CSGBox3D, zone: Dictionary, selected: bool) -> void:
	var a := _xyz_cell(zone["from_cell"])
	var b := _xyz_cell(zone["to_cell"])
	var pa := _center(a.x, a.y, a.z)
	var pb := _center(b.x, b.y, b.z)
	box.position = (pa + pb) * 0.5 + Vector3(0, 1.15, 0)
	if a == b:
		box.size = Vector3(1.6, 1.8, 1.6)
	elif a.x != b.x:
		box.size = Vector3(absf(pb.x - pa.x) + 0.8, 1.8, 1.4)
	else:
		box.size = Vector3(1.4, 1.8, absf(pb.z - pa.z) + 0.8)
	var col: Color = HAZARD_COLORS.get(str(zone.get("kind", "")), Color(0.8, 0.8, 0.3))
	var mat := box.material as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		box.material = mat
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(col.r, col.g, col.b, 0.38)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 0.7 if selected else 0.28
	box.set_meta("kind", str(zone.get("kind", "")))
	box.set_meta("zone_id", str(zone.get("id", "")))
	box.set_meta("deck", a.z)
	if a.z != active_deck and b.z != active_deck:
		mat.albedo_color.a = 0.12


func _update_hazard_ghost(cell: Vector3i) -> void:
	if _has_pending:
		if cell == _pending_cell:
			_place_cell_ghost(cell, "", "click again to cancel %s" % active_hazard_kind)
			return
		var reason := _hazard_block_reason(_pending_cell, cell)
		var ok := "%s (%d,%d) → (%d,%d)" % [
			active_hazard_kind, _pending_cell.x, _pending_cell.y, cell.x, cell.y
		]
		if reason == "" and _find_hazard(_pending_cell, cell, active_hazard_kind) >= 0:
			ok = "select existing %s" % active_hazard_kind
		elif reason == "" and _find_portal(_pending_cell, cell) >= 0:
			ok = "portal-aligned %s" % active_hazard_kind
		if _is_cardinal(_pending_cell, cell):
			_place_edge_ghost(_pending_cell, cell, reason, ok)
			var mat := _ghost.material_override as StandardMaterial3D
			if mat and reason == "":
				var col: Color = HAZARD_COLORS.get(active_hazard_kind, Color(0.8, 0.8, 0.3))
				mat.albedo_color = Color(col.r, col.g, col.b, 0.42)
			return
		_place_cell_ghost(cell, reason if reason != "" else "blocked: hazard endpoints must be cardinal neighbors", "")
		return
	var portal_idx := _portal_index_near(cell, _last_hit)
	if portal_idx >= 0:
		_ghost.visible = false
		hover_info.emit("portal-aligned %s" % active_hazard_kind)
		return
	var existing := _hazard_index_near(cell, _last_hit)
	if existing >= 0:
		_ghost.visible = false
		var found_kind := str(_hazards[existing].get("kind", ""))
		if found_kind == active_hazard_kind:
			hover_info.emit("select %s" % found_kind)
		else:
			hover_info.emit("place %s on existing %s link" % [active_hazard_kind, found_kind])
		return
	if _occupancy.has(_key(cell)):
		_place_cell_ghost(cell, "", "%s from (%d,%d) deck %d" % [active_hazard_kind, cell.x, cell.y, cell.z])
		return
	_place_cell_ghost(cell, "blocked: hazard start must be occupied", "")


func _cell_xyz(cell: Vector3i) -> Array:
	return [cell.x, cell.y, cell.z]


func _xyz_cell(v: Variant) -> Vector3i:
	if v is Vector3i:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3i(int(a[0]), int(a[1]), int(a[2]))
	return Vector3i.ZERO


func _undirected_key(a: Vector3i, b: Vector3i) -> String:
	var ka := _key(a)
	var kb := _key(b)
	if ka < kb:
		return "%s>%s" % [ka, kb]
	return "%s>%s" % [kb, ka]


func _sync_links() -> void:
	if _links == null:
		return
	var wanted_p: Dictionary = {}
	for i in _portals.size():
		var p: Dictionary = _portals[i]
		var k := _undirected_key(_xyz_cell(p["from_cell"]), _xyz_cell(p["to_cell"]))
		wanted_p[k] = i
	var stale_p: Array = []
	for key in _portal_boxes:
		if not wanted_p.has(key):
			stale_p.append(key)
	for key in stale_p:
		var old: CSGBox3D = _portal_boxes[key]
		_links.remove_child(old)
		old.free()
		_portal_boxes.erase(key)
	for key in wanted_p:
		var idx: int = wanted_p[key]
		var p: Dictionary = _portals[idx]
		var box: CSGBox3D
		if _portal_boxes.has(key):
			box = _portal_boxes[key]
		else:
			box = CSGBox3D.new()
			box.use_collision = false
			box.material = StandardMaterial3D.new()
			_links.add_child(box)
			_portal_boxes[key] = box
		_style_portal_box(box, p, idx == _selected_portal and _selected_kind == "portal")
	var wanted_v: Dictionary = {}
	for i in _verticals.size():
		var v: Dictionary = _verticals[i]
		var k := _undirected_key(_xyz_cell(v["from_cell"]), _xyz_cell(v["to_cell"]))
		wanted_v[k] = i
	var stale_v: Array = []
	for key in _vertical_boxes:
		if not wanted_v.has(key):
			stale_v.append(key)
	for key in stale_v:
		var oldv: CSGBox3D = _vertical_boxes[key]
		_links.remove_child(oldv)
		oldv.free()
		_vertical_boxes.erase(key)
	for key in wanted_v:
		var vidx: int = wanted_v[key]
		var vert: Dictionary = _verticals[vidx]
		var vbox: CSGBox3D
		if _vertical_boxes.has(key):
			vbox = _vertical_boxes[key]
		else:
			vbox = CSGBox3D.new()
			vbox.use_collision = false
			vbox.material = StandardMaterial3D.new()
			_links.add_child(vbox)
			_vertical_boxes[key] = vbox
		_style_vertical_box(vbox, vert, vidx == _selected_vertical and _selected_kind == "vertical")
	_sync_hazards()


func _style_portal_box(box: CSGBox3D, portal: Dictionary, selected: bool) -> void:
	var a := _xyz_cell(portal["from_cell"])
	var b := _xyz_cell(portal["to_cell"])
	var pa := _center(a.x, a.y, a.z)
	var pb := _center(b.x, b.y, b.z)
	box.position = (pa + pb) * 0.5 + Vector3(0, 0.7, 0)
	if a.x != b.x:
		box.size = Vector3(0.38, 1.5, CELL_SIZE_M - 0.55)
	else:
		box.size = Vector3(CELL_SIZE_M - 0.55, 1.5, 0.38)
	var state := str(portal.get("state", "DOOR"))
	var col: Color = STATE_COLORS.get(state, Color(0.4, 0.8, 0.9))
	var mat := box.material as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		box.material = mat
	mat.albedo_color = col
	mat.emission_enabled = selected
	if selected:
		mat.emission = col
		mat.emission_energy_multiplier = 0.55
	if a.z != active_deck and b.z != active_deck:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.2
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.albedo_color.a = 1.0


func _style_vertical_box(box: CSGBox3D, vertical: Dictionary, selected: bool) -> void:
	var a := _xyz_cell(vertical["from_cell"])
	var b := _xyz_cell(vertical["to_cell"])
	var pa := _center(a.x, a.y, a.z)
	var pb := _center(b.x, b.y, b.z)
	box.position = (pa + pb) * 0.5 + Vector3(0, 0.2, 0)
	box.size = Vector3(0.7, absf(pb.y - pa.y) + 0.35, 0.7)
	var col := Color(0.45, 0.95, 0.55)
	var mat := box.material as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		box.material = mat
	mat.albedo_color = col
	mat.emission_enabled = selected
	if selected:
		mat.emission = col
		mat.emission_energy_multiplier = 0.5
	if a.z != active_deck and b.z != active_deck:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.22
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color.a = 0.7


func _rebuild_grid() -> void:
	if _grid == null:
		return
	var im := ImmediateMesh.new()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	var y := active_deck * DECK_HEIGHT_M
	for i in range(AABB_MIN, AABB_MAX + 2):
		# Cell edges sit 2 m off world_pos centers so lines match kit modules.
		var t := float(i) * CELL_SIZE_M - CELL_SIZE_M * 0.5
		var major := i % 8 == 0
		var col := Color(0.28, 0.42, 0.62, 0.55) if major else Color(0.18, 0.22, 0.32, 0.35)
		if i == 0:
			col = Color(0.95, 0.45, 0.35, 0.7)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(float(AABB_MIN) * CELL_SIZE_M, y, t))
		im.surface_add_vertex(Vector3(float(AABB_MAX + 1) * CELL_SIZE_M, y, t))
		if i == 0:
			col = Color(0.35, 0.85, 0.55, 0.7)
		im.surface_set_color(col)
		im.surface_add_vertex(Vector3(t, y, float(AABB_MIN) * CELL_SIZE_M))
		im.surface_add_vertex(Vector3(t, y, float(AABB_MAX + 1) * CELL_SIZE_M))
	im.surface_end()
	_grid.mesh = im


func _try_lmb_prop(cell: Vector3i) -> bool:
	var existing := prop_index_at(cell)
	if existing >= 0:
		# Re-click inspects; never restamp the same cell.
		_select_prop(existing)
		return false
	if _armed_prop.is_empty():
		hover_info.emit("select a palette proto first")
		return false
	var reason := _prop_block_reason(cell, _armed_prop)
	if reason != "":
		hover_info.emit(reason)
		return false
	_place_prop(cell, _armed_prop)
	return true


func _select_prop(index: int) -> void:
	if index < 0 or index >= _props.size():
		return
	_selected_kind = "prop"
	_selected_prop = index
	_selected_portal = -1
	_selected_vertical = -1
	_asset_sel = {}
	_selected_hazard = -1
	var cell := _xyz_cell(_props[index].get("cell", []))
	if _occupancy.has(_key(cell)):
		_selected_id = int(_occupancy[_key(cell)])
	_sync_floors()
	_sync_links()
	prop_selected.emit(_prop_dto(_props[index]))


func _place_prop(cell: Vector3i, entry: Dictionary) -> void:
	var facing := _facing_for(cell, _last_hit)
	var base_rot := _PALETTE.rotation_from_facing(facing) if facing != "" else 0
	var kind := _PALETTE.kind_or_skip_door(str(entry.get("kind", "Furniture")))
	if kind.is_empty():
		hover_info.emit("blocked: doors are implied by portals")
		return
	var visual := str(entry.get("visual_id", ""))
	var proto := str(entry.get("proto", entry.get("id", "")))
	var prop := {
		"id": _next_prop_id,
		"kind": kind,
		"proto": proto,
		"visual_id": visual,
		"cell": _cell_xyz(cell),
		"rotation": _PALETTE.clamp_rotation(entry, base_rot + _rotation_offset),
		"facing": facing if facing != "" else null,
		"locked": false,
		"inventory_mode": "empty",
		"inventory": [],
		"loot_table": null,
		"wall_adjacent": _PALETTE.is_wall_adjacent(entry),
		"stand_in": _PALETTE.is_stand_in(entry),
		"visual_scene_path": str(entry.get("visual_scene_path", "")),
		"primitive": str(entry.get("primitive", "")),
		"albedo": str(entry.get("albedo", "")),
		"place": str(entry.get("place", "")),
		"group": str(entry.get("group", "")),
		"allowed_yaw_deg": entry.get("allowed_yaw_deg", []),
	}
	_next_prop_id += 1
	_props.append(prop)
	_selected_kind = "prop"
	_selected_prop = _props.size() - 1
	_selected_portal = -1
	_selected_vertical = -1
	_selected_hazard = -1
	if _occupancy.has(_key(cell)):
		_selected_id = int(_occupancy[_key(cell)])
	_sync_floors()
	props_changed.emit()
	prop_selected.emit(_prop_dto(prop))


func _prop_block_reason(cell: Vector3i, entry: Dictionary) -> String:
	if not _prop_ready:
		return "blocked: compile must succeed before props"
	if str(entry.get("kind", "")) == "Door" or str(entry.get("kind", "")).to_lower() == "door":
		return "blocked: doors are implied by portals"
	var key := _key(cell)
	if not _occupancy.has(key):
		return "blocked: unoccupied"
	if _reserved.has(key):
		return "blocked: doorway-adjacent / vertical reserved"
	if prop_index_at(cell) >= 0:
		return "blocked: one prop per cell"
	var wall_adj := _PALETTE.is_wall_adjacent(entry)
	if wall_adj and not _wall_slots.has(key):
		return "blocked: wall-adjacent proto refuses center slots"
	var place := str(entry.get("place", "Free"))
	var room_id := int(_occupancy[key])
	if place == "Center" and _room_has_center_slots(room_id):
		if not _center_slots.has(key):
			return "blocked: Center proto requires a center slot"
	elif not _wall_slots.has(key) and not _center_slots.has(key):
		return "blocked: not a wall or center slot"
	var need_role := str(entry.get("role", ""))
	if not need_role.is_empty():
		var have := _room_role(int(_occupancy[key]))
		if have != need_role:
			return "blocked: proto is for %s, cell is %s" % [need_role, have]
	return ""


func _room_has_center_slots(room_id: int) -> bool:
	for key in _center_slots:
		if int(_occupancy.get(key, 0)) == room_id:
			return true
	return false


func _facing_for(cell: Vector3i, hit: Vector3) -> String:
	var solids: Array = _solid_dirs.get(_key(cell), [])
	var clicked := _hit_dir(cell, hit)
	if clicked != "" and solids.has(clicked):
		return clicked
	return _PALETTE.first_solid_dir(solids)


func _hit_dir(cell: Vector3i, hit: Vector3) -> String:
	var half := CELL_SIZE_M * 0.5
	var lx := hit.x - float(cell.x) * CELL_SIZE_M + half
	var lz := hit.z - float(cell.y) * CELL_SIZE_M + half
	var band := 1.05
	var best := ""
	var best_d := band
	if lx < band:
		var d: float = lx
		if d < best_d:
			best_d = d
			best = "west"
	if lx > CELL_SIZE_M - band:
		var d2: float = CELL_SIZE_M - lx
		if d2 < best_d:
			best_d = d2
			best = "east"
	if lz < band:
		var d3: float = lz
		if d3 < best_d:
			best_d = d3
			best = "north"
	if lz > CELL_SIZE_M - band:
		var d4: float = CELL_SIZE_M - lz
		if d4 < best_d:
			best = "south"
	return best


func _update_prop_ghost(cell: Vector3i) -> void:
	var existing := prop_index_at(cell)
	if existing >= 0:
		_ghost.visible = false
		hover_info.emit("select %s  (%d,%d deck %d)" % [
			str(_props[existing].get("proto", "prop")), cell.x, cell.y, cell.z
		])
		return
	if _armed_prop.is_empty():
		_ghost.visible = false
		hover_info.emit("select a palette proto")
		return
	var reason := _prop_block_reason(cell, _armed_prop)
	var facing := _facing_for(cell, _last_hit)
	var rot := posmod(_PALETTE.rotation_from_facing(facing) + _rotation_offset, 4)
	var ok := "place %s rot %d" % [str(_armed_prop.get("proto", "")), rot]
	if facing != "":
		ok += " facing %s" % facing
	if _PALETTE.is_stand_in(_armed_prop):
		ok += " (preview stand-in)"
	_place_cell_ghost(cell, reason, ok)
	if _ghost.visible:
		_ghost.position = _center(cell.x, cell.y, cell.z) + Vector3(0, 0.6, 0)
		var gmesh := _ghost.mesh as BoxMesh
		if gmesh:
			gmesh.size = Vector3(0.9, 1.1, 0.9)
		_ghost.rotation_degrees = Vector3(0, float(rot) * 90.0, 0)


func _ingest_zones(zones: Dictionary) -> void:
	_reserved.clear()
	_wall_slots.clear()
	_center_slots.clear()
	for room_key in zones:
		var z: Variant = zones[room_key]
		if not (z is Dictionary):
			continue
		var rec: Dictionary = z
		_ingest_cell_list(rec.get("reserved_cells", []), _reserved)
		_ingest_cell_list(rec.get("wall_slots", []), _wall_slots)
		_ingest_cell_list(rec.get("center_slots", []), _center_slots)


func _ingest_cell_list(cells: Variant, into: Dictionary) -> void:
	if not (cells is Array):
		return
	for c in cells:
		into[_key(_xyz_cell(c))] = true


func _ingest_solids(plan: Dictionary) -> void:
	_solid_dirs.clear()
	var edges: Variant = plan.get("edges", {})
	if not (edges is Dictionary):
		return
	for edge_key in edges:
		var rec_v: Variant = edges[edge_key]
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var kind := str(rec.get("kind", rec.get("state", "")))
		if kind != "SOLID":
			continue
		var dir := str(rec.get("direction", ""))
		if dir.is_empty():
			continue
		var owner := _edge_owner_cell(rec)
		_add_solid_dir(owner, dir)
		# Compile stores the undirected edge once on the BTreeMap-first cell.
		# The other occupied side is still a wall_slot and faces the opposite Dir.
		var other := _edge_other_cell(rec, owner)
		if other != owner and _occupancy.has(_key(other)):
			var opp := str(rec.get("opposite_direction", ""))
			if opp.is_empty():
				opp = _opposite_dir(dir)
			_add_solid_dir(other, opp)


func _edge_owner_cell(rec: Dictionary) -> Vector3i:
	var deck := int(rec.get("deck", 0))
	var cell_v: Variant = rec.get("cell", [])
	if cell_v is Array and (cell_v as Array).size() >= 2:
		var a: Array = cell_v
		var x := int(a[0])
		var y := int(a[1])
		if a.size() >= 3:
			deck = int(a[2])
		return Vector3i(x, y, deck)
	return Vector3i.ZERO


func _edge_other_cell(rec: Dictionary, owner: Vector3i) -> Vector3i:
	var src: Variant = rec.get("source_cells", [])
	if not (src is Array) or (src as Array).size() < 2:
		return owner
	var other := _xyz_cell((src as Array)[1])
	if other == owner:
		other = _xyz_cell((src as Array)[0])
	return other


func _add_solid_dir(cell: Vector3i, dir: String) -> void:
	if dir.is_empty():
		return
	var key := _key(cell)
	var arr: Array = _solid_dirs.get(key, [])
	if arr.find(dir) < 0:
		arr.append(dir)
	_solid_dirs[key] = arr


func _opposite_dir(dir: String) -> String:
	match dir:
		"north":
			return "south"
		"south":
			return "north"
		"east":
			return "west"
		"west":
			return "east"
		_:
			return ""


func _prune_props() -> bool:
	var next: Array[Dictionary] = []
	var changed := false
	var keep_sel := -1
	for i in _props.size():
		var p: Dictionary = _props[i]
		var cell := _xyz_cell(p.get("cell", []))
		var key := _key(cell)
		var drop := false
		if not _occupancy.has(key):
			drop = true
		elif _prop_ready and _reserved.has(key):
			drop = true
		elif _prop_ready and bool(p.get("wall_adjacent", false)) and not _wall_slots.has(key):
			drop = true
		elif _prop_ready and not _wall_slots.has(key) and not _center_slots.has(key):
			drop = true
		if drop:
			changed = true
			continue
		if _selected_kind == "prop" and i == _selected_prop:
			keep_sel = next.size()
		next.append(p)
	_props = next
	if _selected_kind == "prop":
		_selected_prop = keep_sel
		if _selected_prop < 0:
			_selected_kind = "room"
	return changed


func _prop_dto(prop: Dictionary) -> Dictionary:
	var facing: Variant = prop.get("facing", null)
	if facing is String and str(facing).is_empty():
		facing = null
	var loot: Variant = prop.get("loot_table", null)
	if loot is String and str(loot).is_empty():
		loot = null
	# AuthoredProp fields only. Extra preview keys stay in-memory on `_props`.
	return {
		"id": int(prop.get("id", 0)),
		"kind": str(prop.get("kind", "Furniture")),
		"proto": str(prop.get("proto", "")),
		"visual_id": str(prop.get("visual_id", "")),
		"cell": prop.get("cell", [0, 0, 0]),
		"rotation": int(prop.get("rotation", 0)),
		"facing": facing,
		"locked": bool(prop.get("locked", false)),
		"inventory_mode": str(prop.get("inventory_mode", "empty")),
		"inventory": prop.get("inventory", []),
		"loot_table": loot,
	}


func _sync_slots() -> void:
	if _slots == null:
		return
	_slots.visible = _show_slots and _prop_ready
	if not _slots.visible:
		return
	var wanted: Dictionary = {}
	for key in _reserved:
		wanted[key] = "reserved"
	for key in _wall_slots:
		wanted[key] = "wall"
	for key in _center_slots:
		wanted[key] = "center"
	var stale: Array = []
	for key in _slot_boxes:
		if not wanted.has(key):
			stale.append(key)
	for key in stale:
		var old: CSGBox3D = _slot_boxes[key]
		_slots.remove_child(old)
		old.free()
		_slot_boxes.erase(key)
	for key in wanted:
		var kind: String = wanted[key]
		var cell := _cell_from_key(str(key))
		var box: CSGBox3D
		if _slot_boxes.has(key):
			box = _slot_boxes[key]
		else:
			box = CSGBox3D.new()
			box.use_collision = false
			box.size = Vector3(CELL_SIZE_M - 0.35, 0.08, CELL_SIZE_M - 0.35)
			box.position = _center(cell.x, cell.y, cell.z) + Vector3(0, 0.12, 0)
			box.material = StandardMaterial3D.new()
			_slots.add_child(box)
			_slot_boxes[key] = box
		_style_slot_box(box, kind, cell.z)


func _style_slot_box(box: CSGBox3D, kind: String, deck: int) -> void:
	var col := Color(0.95, 0.28, 0.28, 0.28)
	match kind:
		"wall":
			col = Color(0.95, 0.72, 0.22, 0.28)
		"center":
			col = Color(0.28, 0.85, 0.95, 0.28)
	if deck != active_deck:
		col.a = 0.08 if deck > active_deck else 0.14
	var mat := box.material as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		box.material = mat
	mat.albedo_color = col
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
