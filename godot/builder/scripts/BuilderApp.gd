class_name BuilderApp
extends Control
## Standalone occupancy author. Owns the GoldenArea dict and live-compiles
## through DerelictAuthor on a 50 ms debounce. CSG floors only.

const COMPILE_DEBOUNCE_S := 0.05

var author
var golden: Dictionary = {}
var _room_vars: Dictionary = {}
var _doc_id := "untitled"
var _display_name := "Untitled"
var _entry_room := ""
var _goal_room := ""
var _compile_timer: Timer

@onready var _banner: PanelContainer = %Banner
@onready var _banner_label: Label = %BannerLabel
@onready var _phase_bar: TabBar = %PhaseBar
@onready var _deck_label: Label = %DeckLabel
@onready var _iso_btn: Button = %IsoBtn
@onready var _role_list: VBoxContainer = %RoleList
@onready var _room_list: ItemList = %RoomList
@onready var _view: SubViewportContainer = %View
@onready var _viewport: SubViewport = %SubViewport
@onready var _lattice = %OccupancyLattice
@onready var _inspector = %InspectorDock
@onready var _issues: ItemList = %IssuesList
@onready var _status: Label = %StatusLabel
@onready var _content = %ContentRoot
@onready var _root_label: Label = %RootLabel


func _ready() -> void:
	_build_phases()
	_build_roles()
	_wire()
	golden = _empty_golden()
	if ClassDB.class_exists("DerelictAuthor"):
		author = ClassDB.instantiate("DerelictAuthor")
	_resolve_content()
	_schedule_compile()
	_sync_deck_label()
	_status.text = "LMB paint · RMB erase · click room stamps role · Q/E [ ] deck · MMB pan/orbit · wheel zoom"


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	if _lattice.is_painting():
		return
	match event.keycode:
		KEY_Q, KEY_BRACKETLEFT:
			_lattice.nudge_deck(-1)
			get_viewport().set_input_as_handled()
		KEY_E, KEY_BRACKETRIGHT:
			_lattice.nudge_deck(1)
			get_viewport().set_input_as_handled()


func _wire() -> void:
	%DeckDown.pressed.connect(func() -> void: _lattice.nudge_deck(-1))
	%DeckUp.pressed.connect(func() -> void: _lattice.nudge_deck(1))
	%AddDeck.pressed.connect(func() -> void: _lattice.add_deck())
	_iso_btn.pressed.connect(_toggle_iso)
	%NewRoomBtn.pressed.connect(func() -> void: _lattice.create_room())
	_view.gui_input.connect(_on_view_gui_input)
	_view.mouse_exited.connect(func() -> void: _lattice.hide_ghost())
	_lattice.occupancy_changed.connect(_on_occupancy_changed)
	_lattice.room_selected.connect(_on_room_selected)
	_lattice.deck_changed.connect(func(_d: int) -> void: _sync_deck_label())
	_lattice.hover_info.connect(func(t: String) -> void: _status.text = t)
	_inspector.room_edited.connect(_on_room_edited)
	_room_list.item_selected.connect(_on_room_list_selected)
	_compile_timer = Timer.new()
	_compile_timer.one_shot = true
	_compile_timer.wait_time = COMPILE_DEBOUNCE_S
	_compile_timer.timeout.connect(_run_compile)
	add_child(_compile_timer)


func _build_phases() -> void:
	_phase_bar.add_tab("1 Floor plan")
	_phase_bar.add_tab("2 Props")
	_phase_bar.add_tab("3 Assets")
	_phase_bar.add_tab("4 Hazards")
	_phase_bar.set_tab_disabled(1, true)
	_phase_bar.set_tab_disabled(2, true)
	_phase_bar.set_tab_disabled(3, true)
	_phase_bar.current_tab = 0


func _build_roles() -> void:
	for role in OccupancyLattice.ROLES:
		var b := Button.new()
		b.text = role
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_role_pressed.bind(role))
		_role_list.add_child(b)
	_highlight_armed_role()


func _on_role_pressed(role: String) -> void:
	_lattice.stamp_role(role)
	_highlight_armed_role()


func _highlight_armed_role() -> void:
	var armed := str(_lattice.active_role)
	for child in _role_list.get_children():
		var b := child as Button
		if b == null:
			continue
		b.modulate = Color(1.15, 1.1, 0.65) if b.text == armed else Color.WHITE


func _toggle_iso() -> void:
	_lattice.set_iso(not _lattice.is_iso())
	_iso_btn.text = "Cam: Iso" if _lattice.is_iso() else "Cam: Orbit"


func _on_view_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var focused := get_viewport().gui_get_focus_owner()
		if focused:
			focused.release_focus()
	_lattice.handle_gui_input(event, _viewport)


func _on_occupancy_changed() -> void:
	_sync_entry_goal()
	_prune_room_vars()
	_refresh_room_list()
	_schedule_compile()


func _on_room_selected(room: Dictionary) -> void:
	if room.is_empty():
		_inspector.clear()
		_room_list.deselect_all()
		return
	var id := int(room["id"])
	_inspector.bind_room(room, _ensure_vars(id))
	for i in _room_list.item_count:
		if int(_room_list.get_item_metadata(i)) == id:
			_room_list.select(i)
			break


func _on_room_edited(room: Dictionary, vars: Dictionary) -> void:
	var id := int(room.get("id", 0))
	_room_vars[str(id)] = vars
	_lattice.apply_room_edit(room)
	if _entry_room.is_empty():
		_entry_room = str(room.get("stable_id", ""))
	_schedule_compile()


func _on_room_list_selected(index: int) -> void:
	var id := int(_room_list.get_item_metadata(index))
	_lattice.select_room_id(id)


func _refresh_room_list() -> void:
	var selected: Dictionary = _lattice.get_selected()
	var sel_id := int(selected.get("id", 0))
	_room_list.clear()
	for r in _lattice.get_rooms():
		var n: int = (r["cells"] as Array).size()
		var i := _room_list.add_item("%s  %s  d%d  %d cells" % [
			r["stable_id"], r["role"], int(r["deck"]), n
		])
		_room_list.set_item_metadata(i, int(r["id"]))
		if int(r["id"]) == sel_id:
			_room_list.select(i)


func _sync_deck_label() -> void:
	_deck_label.text = "Deck %d / %d" % [_lattice.active_deck, _lattice.deck_count - 1]


func _resolve_content() -> void:
	if author == null:
		_banner.visible = true
		_banner_label.text = "DerelictAuthor missing. Run scripts/build_windows.ps1 -Builder."
		_root_label.text = "content root: (extension missing)"
		return
	var info: Dictionary = _content.resolve()
	_banner.visible = bool(info.get("offline", true))
	if info.get("offline", true):
		_banner_label.text = "Offline: no Synaptic Sea content root — palettes from embedded RON, CSG floors only."
		_root_label.text = "content root: (offline)"
		author.set_content_root("")
		return
	var path := str(info.get("path", ""))
	_root_label.text = "content root: %s (%s)" % [path, info.get("source", "")]
	var result: Dictionary = author.set_content_root(path)
	if not bool(result.get("ok", false)):
		_banner.visible = true
		var errs: Array = result.get("errors", [])
		var msg := "Content root loaded with errors"
		if not errs.is_empty():
			msg += ": " + str(errs[0])
		_banner_label.text = msg


func _schedule_compile() -> void:
	golden = _golden_from_lattice()
	_compile_timer.start(COMPILE_DEBOUNCE_S)


func _run_compile() -> void:
	if author == null:
		_show_issues([{"code": "Extension", "detail": "DerelictAuthor missing. Run scripts/build_windows.ps1 -Builder."}])
		return
	var result: Dictionary = author.compile(golden)
	if result.has("error"):
		_show_issues([{"code": "Compile", "detail": str(result["error"])}])
		return
	var issues: Array = result.get("issues", [])
	_show_issues(issues)


func _show_issues(issues: Array) -> void:
	_issues.clear()
	if issues.is_empty():
		_issues.add_item("Compile OK")
		return
	for iss in issues:
		if iss is Dictionary:
			_issues.add_item("%s: %s" % [iss.get("code", "?"), iss.get("detail", "")])
		else:
			_issues.add_item(str(iss))


func _sync_entry_goal() -> void:
	var rooms: Array = _lattice.get_rooms()
	if rooms.is_empty():
		_entry_room = ""
		_goal_room = ""
		return
	var ids: Dictionary = {}
	for r in rooms:
		ids[str(r["stable_id"])] = true
	if _entry_room.is_empty() or not ids.has(_entry_room):
		_entry_room = str(rooms[0]["stable_id"])
	if _goal_room.is_empty() or not ids.has(_goal_room):
		_goal_room = _entry_room


func _prune_room_vars() -> void:
	var live: Dictionary = {}
	for r in _lattice.get_rooms():
		var k := str(int(r["id"]))
		live[k] = _ensure_vars(int(r["id"]))
	_room_vars = live


func _ensure_vars(id: int) -> Dictionary:
	var k := str(id)
	if not _room_vars.has(k):
		_room_vars[k] = {
			"oxygen_bp": 8500,
			"depressurized": false,
			"vented": false,
			"radiation_bp": 0,
			"temperature_c": 18,
			"notes": "",
		}
	return _room_vars[k]


func _empty_golden() -> Dictionary:
	return {
		"schema_version": "1.0.0",
		"document_kind": "golden_area",
		"id": _doc_id,
		"display_name": _display_name,
		"scope": "room",
		"kit_id": "ship_structural_v0",
		"cell_size_m": 4.0,
		"deck_height_m": 4.0,
		"entry_room": "",
		"goal_room": "",
		"topology": {"rooms": [], "portals": [], "verticals": []},
		"module_overrides": {"floors": {}, "ceilings": {}, "edges": {}},
		"props": [],
		"room_vars": {},
		"hazards": {
			"source": "authored",
			"fire_zones": [],
			"breach_zones": [],
			"arc_zones": [],
			"radiation_zones": [],
		},
	}


func _golden_from_lattice() -> Dictionary:
	var rooms: Array = []
	for r in _lattice.get_rooms():
		var cells: Array = []
		for c in r["cells"]:
			var p: Vector2i = c
			cells.append([p.x, p.y])
		rooms.append({
			"id": int(r["id"]),
			"stable_id": str(r["stable_id"]),
			"role": str(r["role"]),
			"deck": int(r["deck"]),
			"cells": cells,
		})
	var scope := "room"
	if rooms.size() > 1:
		scope = "area"
	var g := _empty_golden()
	g["id"] = _doc_id
	g["display_name"] = _display_name
	g["scope"] = scope
	g["entry_room"] = _entry_room
	g["goal_room"] = _goal_room
	g["topology"] = {"rooms": rooms, "portals": [], "verticals": []}
	g["room_vars"] = _room_vars.duplicate(true)
	return g
