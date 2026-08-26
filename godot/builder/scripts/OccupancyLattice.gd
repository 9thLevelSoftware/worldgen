class_name OccupancyLattice
extends Node3D
## 3D occupancy lattice (not a TileMapLayer). Cells snap to CELL_SIZE_M.
## Occupancy paint/erase plus click-click portals and stacked verticals.

signal occupancy_changed
signal room_selected(room: Dictionary)
signal portal_selected(portal: Dictionary)
signal vertical_selected(vertical: Dictionary)
signal deck_changed(deck: int)
signal hover_info(text: String)
signal tool_changed(tool: String)

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

## EdgeKind::name() portal states only (not SOLID/OPEN).
const PORTAL_STATES: PackedStringArray = ["DOOR", "LOCKED", "HATCH", "BREACH"]

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

var _rooms: Array[Dictionary] = []
var _occupancy: Dictionary = {} # "deck|x|y" -> room id
var _portals: Array[Dictionary] = []
var _verticals: Array[Dictionary] = []
var _selected_id: int = 0
var _selected_kind: String = "room"
var _selected_portal: int = -1
var _selected_vertical: int = -1
var _next_id: int = 1
var _has_pending := false
var _pending_cell := Vector3i.ZERO

var _camera: Camera3D
var _pivot: Node3D
var _floors: Node3D
var _floor_boxes: Dictionary = {} # "deck|x|y" -> CSGBox3D
var _links: Node3D
var _portal_boxes: Dictionary = {}
var _vertical_boxes: Dictionary = {}
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
	_has_last_screen = false
	hide_ghost()


## Arm a new room; the RoomSpec is created on the next successful void paint.
func create_room() -> void:
	_cancel_pending()
	_selected_id = 0
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	_sync_floors()
	_sync_links()
	room_selected.emit({})


## Re-applying the same tool still resets the pending click (plain buttons).
func set_tool(tool: String) -> void:
	if tool != TOOL_PAINT and tool != TOOL_PORTAL and tool != TOOL_VERTICAL:
		return
	active_tool = tool
	_cancel_pending()
	_refresh_ghost()
	tool_changed.emit(active_tool)


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
	_sync_links()
	occupancy_changed.emit()
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
	return false


func cancel_pending() -> void:
	if not _has_pending:
		return
	_cancel_pending()
	_refresh_ghost()
	hover_info.emit("pending click cancelled")


func stamp_role(role: String) -> void:
	active_role = role
	# Role palette is a room stamp. Drop portal/vertical selection so the
	# inspector and Delete/Backspace match the highlighted room.
	var converted := _selected_kind == "portal" or _selected_kind == "vertical"
	if converted:
		_selected_kind = "room"
		_selected_portal = -1
		_selected_vertical = -1
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
	_sync_floors()
	_sync_links()
	if changed:
		occupancy_changed.emit()
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
		_sync_floors()
		_sync_links()
		occupancy_changed.emit()
		room_selected.emit(r)
		return


func select_room_id(id: int) -> void:
	_cancel_pending()
	_selected_id = id
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
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
				if _has_pending and not _occupancy.has(_key(c)):
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
		elif _rmb:
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
		_:
			return _try_lmb_paint(cell)


func _try_lmb_paint(cell: Vector3i) -> bool:
	var key := _key(cell)
	if _occupancy.has(key):
		var id := int(_occupancy[key])
		# Re-click of the active room is inspect-only so inspector role
		# edits are not overwritten by the armed palette stamp.
		var stamped := false
		if id != _selected_id:
			stamped = _stamp_room_id(id, active_role)
		select_room_id(id)
		if stamped:
			occupancy_changed.emit()
		return false
	return _try_paint(cell)


func _try_paint(cell: Vector3i) -> bool:
	var reason := _paint_block_reason(cell)
	if reason != "":
		hover_info.emit(reason)
		return false
	var room := get_selected()
	var need_new := room.is_empty()
	if not need_new and not (room["cells"] as Array).is_empty():
		if int(room["deck"]) != cell.z:
			need_new = true
	if need_new:
		room = _make_room(active_role, cell.z)
		_rooms.append(room)
		_selected_id = int(room["id"])
	if (room["cells"] as Array).is_empty():
		room["deck"] = cell.z
	(room["cells"] as Array).append(Vector2i(cell.x, cell.y))
	_occupancy[_key(cell)] = int(room["id"])
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	_prune_links()
	_sync_deck_count()
	_sync_floors()
	_sync_links()
	occupancy_changed.emit()
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
	_sync_floors()
	_sync_links()
	occupancy_changed.emit()
	_emit_selection()


func _paint_block_reason(cell: Vector3i) -> String:
	if cell.z < 0 or cell.z >= MAX_DECKS:
		return "blocked: max 8 decks"
	if not _in_aabb(cell.x, cell.y):
		return "blocked: soft AABB 64×64"
	if _occupancy.has(_key(cell)):
		return "blocked: occupancy overlap"
	var room := get_selected()
	if room.is_empty() or (room["cells"] as Array).is_empty():
		return ""
	if int(room["deck"]) != cell.z:
		return ""
	if _shares_cardinal(room, Vector2i(cell.x, cell.y)):
		return ""
	return "blocked: not 4-adjacent to room"


func _shares_cardinal(room: Dictionary, cell: Vector2i) -> bool:
	for c in room["cells"]:
		var p: Vector2i = c
		for d in CARDINALS:
			if p + d == cell:
				return true
	return false


func _in_aabb(x: int, y: int) -> bool:
	return x >= AABB_MIN and x <= AABB_MAX and y >= AABB_MIN and y <= AABB_MAX


func _stamp_room_id(id: int, role: String) -> bool:
	for r in _rooms:
		if int(r["id"]) != id:
			continue
		if str(r["role"]) == role:
			return false
		r["role"] = role
		return true
	return false


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
		if id == _selected_id or sid.is_empty() or str(_room_role(id)) == active_role:
			hover_info.emit("select %s  (%d,%d deck %d)" % [sid, cell.x, cell.y, cell.z])
		else:
			hover_info.emit("stamp %s on %s  (%d,%d deck %d)" % [
				active_role, sid, cell.x, cell.y, cell.z
			])
		return
	_place_cell_ghost(cell, _paint_block_reason(cell), "paint (%d,%d) deck %d" % [cell.x, cell.y, cell.z])


func _room_role(id: int) -> String:
	for r in _rooms:
		if int(r["id"]) == id:
			return str(r["role"])
	return ""


func _color_for(room: Dictionary) -> Color:
	var role := str(room.get("role", "compartment"))
	var base: Color = ROLE_COLORS.get(role, Color(0.55, 0.58, 0.6))
	var h := fmod(float(int(room.get("id", 1))) * 0.17, 1.0)
	return base.lerp(Color.from_hsv(h, 0.35, 0.85), 0.22)


func _style_floor_box(box: CSGBox3D, room: Dictionary, deck: int) -> void:
	var col := _color_for(room)
	var mat := box.material as StandardMaterial3D
	if mat == null:
		mat = StandardMaterial3D.new()
		box.material = mat
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
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	room_selected.emit(get_selected())


func _cancel_pending() -> void:
	_has_pending = false
	_pending_cell = Vector3i.ZERO
	_sync_pending_anchor()


## First click of a two-click tool. Drops portal/vertical inspect so the
## state palette cannot restamp the previous selection.
func _begin_pending(cell: Vector3i) -> void:
	_has_pending = true
	_pending_cell = cell
	_selected_kind = "room"
	_selected_portal = -1
	_selected_vertical = -1
	if _occupancy.has(_key(cell)):
		_selected_id = int(_occupancy[_key(cell)])
	_sync_pending_anchor()
	_sync_floors()
	_sync_links()
	room_selected.emit(get_selected())


func _sync_pending_anchor() -> void:
	if _anchor == null:
		return
	_anchor.visible = _has_pending
	if _has_pending:
		_anchor.position = _center(_pending_cell.x, _pending_cell.y, _pending_cell.z) + Vector3(0, 0.12, 0)


func _place_cell_ghost(cell: Vector3i, reason: String, ok_text: String) -> void:
	_ghost.visible = true
	_ghost.position = _center(cell.x, cell.y, cell.z)
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
