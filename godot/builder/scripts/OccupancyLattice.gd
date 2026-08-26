class_name OccupancyLattice
extends Node3D
## 3D occupancy lattice (not a TileMapLayer). Cells snap to CELL_SIZE_M.
## Occupancy paint / erase / room / role / deck only. No portal tools.

signal occupancy_changed
signal room_selected(room: Dictionary)
signal deck_changed(deck: int)
signal hover_info(text: String)

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

var _rooms: Array[Dictionary] = []
var _occupancy: Dictionary = {} # "deck|x|y" -> room id
var _selected_id: int = 0
var _next_id: int = 1

var _camera: Camera3D
var _pivot: Node3D
var _floors: Node3D
var _floor_boxes: Dictionary = {} # "deck|x|y" -> CSGBox3D
var _grid: MeshInstance3D
var _ghost: MeshInstance3D
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


func is_painting() -> bool:
	return _lmb or _rmb


## Arm a new room; the RoomSpec is created on the next successful void paint.
func create_room() -> void:
	_selected_id = 0
	room_selected.emit({})


func stamp_role(role: String) -> void:
	active_role = role
	var room := get_selected()
	if room.is_empty():
		return
	if str(room["role"]) == role:
		return
	room["role"] = role
	_sync_floors()
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
		occupancy_changed.emit()
		room_selected.emit(r)
		return


func select_room_id(id: int) -> void:
	_selected_id = id
	_sync_floors()
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
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_paint_drag = _try_lmb(c)
			_accept(host)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
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
		_update_ghost(c)
		if _lmb and _paint_drag:
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
	var x := int(floor(p.x / CELL_SIZE_M))
	var y := int(floor(p.z / CELL_SIZE_M))
	return {"ok": true, "cell": Vector3i(x, y, active_deck)}


func _try_lmb(cell: Vector3i) -> bool:
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
	_sync_deck_count()
	_sync_floors()
	occupancy_changed.emit()
	room_selected.emit(room)
	return true


func _erase_cell(cell: Vector3i) -> void:
	var key := _key(cell)
	if not _occupancy.has(key):
		return
	var id := int(_occupancy[key])
	_occupancy.erase(key)
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
		r["cells"] = cells
		if cells.is_empty():
			if _selected_id == id:
				_selected_id = 0
			continue
		leftover.append(r)
	_rooms = leftover
	_sync_floors()
	occupancy_changed.emit()
	room_selected.emit(get_selected())


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
	if not _has_last_screen:
		hide_ghost()
		_has_last_screen = false
		return
	var cell := _pick_cell(_last_screen)
	if cell.get("ok", false):
		_update_ghost(cell["cell"])
	else:
		if _ghost:
			_ghost.visible = false


func _key(cell: Vector3i) -> String:
	return "%d|%d|%d" % [cell.z, cell.x, cell.y]


func _cell_from_key(key: String) -> Vector3i:
	var parts := key.split("|")
	if parts.size() != 3:
		return Vector3i.ZERO
	return Vector3i(int(parts[1]), int(parts[2]), int(parts[0]))


func _center(x: int, y: int, deck: int) -> Vector3:
	return Vector3(
		x * CELL_SIZE_M + CELL_SIZE_M * 0.5,
		deck * DECK_HEIGHT_M,
		y * CELL_SIZE_M + CELL_SIZE_M * 0.5
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
	_ghost.visible = true
	_ghost.position = _center(cell.x, cell.y, cell.z)
	var mat := _ghost.material_override as StandardMaterial3D
	var reason := _paint_block_reason(cell)
	if reason == "":
		mat.albedo_color = Color(0.45, 1.0, 0.5, 0.35)
		hover_info.emit("paint (%d,%d) deck %d" % [cell.x, cell.y, cell.z])
	else:
		mat.albedo_color = Color(1.0, 0.28, 0.22, 0.4)
		hover_info.emit(reason)


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
		var t := float(i) * CELL_SIZE_M
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
