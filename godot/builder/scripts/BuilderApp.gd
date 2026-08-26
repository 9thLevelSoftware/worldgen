class_name BuilderApp
extends Control
## Standalone occupancy author. Owns the GoldenArea dict and live-compiles
## through DerelictAuthor on a 50 ms debounce. StructuralPlan GLB preview.

const _LATTICE := preload("res://scripts/OccupancyLattice.gd")
const COMPILE_DEBOUNCE_S := 0.05

var author
var golden: Dictionary = {}
var _room_vars: Dictionary = {}
var _palettes: Dictionary = {}
var _module_overrides: Dictionary = {"floors": {}, "ceilings": {}, "edges": {}}
var _edge_override_kinds: Dictionary = {}
var _dressed: Dictionary = {"floors": {}, "ceilings": {}, "edges": {}}
var _last_plan: Dictionary = {}
var _module_sel: Dictionary = {}
var _content_offline := true
var _doc_id := "untitled"
var _display_name := "Untitled"
var _entry_room := ""
var _goal_room := ""
var _compile_ok := false
var _compile_timer: Timer
var _export_dialog: FileDialog

@onready var _banner: PanelContainer = %Banner
@onready var _banner_label: Label = %BannerLabel
@onready var _phase_bar: TabBar = %PhaseBar
@onready var _deck_label: Label = %DeckLabel
@onready var _iso_btn: Button = %IsoBtn
@onready var _export_btn: Button = %ExportBtn
@onready var _tool_list: VBoxContainer = %ToolList
@onready var _state_title: Label = %StateTitle
@onready var _state_list: VBoxContainer = %StateList
@onready var _role_list: VBoxContainer = %RoleList
@onready var _role_scroll: ScrollContainer = $VBox/Body/LeftDock/RoleScroll
@onready var _role_title: Label = $VBox/Body/LeftDock/LeftTitle
@onready var _tools_title: Label = $VBox/Body/LeftDock/ToolsTitle
@onready var _new_room_btn: Button = %NewRoomBtn
var _hazard_title: Label
var _hazard_list: VBoxContainer
@onready var _palette = %PaletteDock
@onready var _room_list: ItemList = %RoomList
@onready var _view: SubViewportContainer = %View
@onready var _viewport: SubViewport = %SubViewport
@onready var _lattice = %OccupancyLattice
@onready var _preview = %StructuralPreview
@onready var _inspector = %InspectorDock
@onready var _issues: ItemList = %IssuesList
@onready var _status: Label = %StatusLabel
@onready var _content = %ContentRoot
@onready var _root_label: Label = %RootLabel


func _ready() -> void:
	_build_phases()
	_build_tools()
	_build_roles()
	_wire()
	golden = _empty_golden()
	if ClassDB.class_exists("DerelictAuthor"):
		author = ClassDB.instantiate("DerelictAuthor")
	_resolve_content()
	_schedule_compile()
	_sync_deck_label()
	_refresh_phases()
	_apply_phase(0)
	_status.text = "Paint LMB · RMB erase · Portal: click A then neighbor · Vertical: stacked N/N±1 · Assign module: click compiled floor/wall/portal · Hazards: Phase 4 · Del removes selected · Esc cancels pending · Q/E deck"


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	if _lattice.is_painting():
		return
	match event.keycode:
		KEY_ESCAPE:
			_lattice.cancel_pending()
			get_viewport().set_input_as_handled()
		KEY_DELETE, KEY_BACKSPACE:
			if _lattice.remove_selected_link():
				get_viewport().set_input_as_handled()
		KEY_R:
			if _lattice.cycle_prop_rotation(event.shift_pressed):
				get_viewport().set_input_as_handled()
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
	_export_btn.pressed.connect(_on_export_pressed)
	_export_dialog = FileDialog.new()
	_export_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_export_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_export_dialog.title = "Export layout.json + gameplay_slice.json"
	_export_dialog.min_size = Vector2i(720, 420)
	_export_dialog.dir_selected.connect(_on_export_dir)
	add_child(_export_dialog)
	%NewRoomBtn.pressed.connect(func() -> void: _lattice.create_room())
	_view.gui_input.connect(_on_view_gui_input)
	_view.mouse_exited.connect(_on_view_pointer_cancelled)
	_lattice.occupancy_changed.connect(_on_occupancy_changed)
	_lattice.room_selected.connect(_on_room_selected)
	_lattice.portal_selected.connect(_on_portal_selected)
	_lattice.vertical_selected.connect(_on_vertical_selected)
	_lattice.prop_selected.connect(_on_prop_selected)
	_lattice.props_changed.connect(_on_props_changed)
	_lattice.piece_selected.connect(_on_piece_selected)
	_lattice.hazard_selected.connect(_on_hazard_selected)
	_lattice.hazards_changed.connect(_on_hazards_changed)
	_lattice.tool_changed.connect(_on_tool_changed)
	_lattice.deck_changed.connect(_on_deck_changed)
	_lattice.hover_info.connect(func(t: String) -> void: _status.text = t)
	_inspector.room_edited.connect(_on_room_edited)
	_inspector.portal_edited.connect(_on_portal_edited)
	_inspector.portal_removed.connect(func() -> void: _lattice.remove_selected_portal())
	_inspector.vertical_removed.connect(func() -> void: _lattice.remove_selected_vertical())
	_inspector.prop_edited.connect(func(p: Dictionary) -> void: _lattice.apply_prop_edit(p))
	_inspector.prop_removed.connect(func() -> void: _lattice.remove_selected_prop())
	_inspector.module_override_set.connect(_on_module_override_set)
	_inspector.module_inspect_requested.connect(_on_piece_selected)
	_inspector.hazard_edited.connect(func(z: Dictionary) -> void: _lattice.apply_hazard_edit(z))
	_inspector.hazard_removed.connect(func() -> void: _lattice.remove_selected_hazard())
	_palette.prop_armed.connect(func(e: Dictionary) -> void: _lattice.arm_prop(e))
	_phase_bar.tab_changed.connect(_on_phase_tab)
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
	_phase_bar.set_tab_disabled(3, false)
	_phase_bar.current_tab = 0


func _on_phase_tab(idx: int) -> void:
	if idx == 1 and not _compile_ok:
		_phase_bar.current_tab = 0
		return
	if idx == 2:
		if _lattice.get_rooms().is_empty():
			_phase_bar.current_tab = 0
			return
		_apply_phase(idx)
		return
	_apply_phase(idx)


func _apply_phase(idx: int) -> void:
	var props_phase: bool = idx == 1 and _compile_ok
	var assets_phase: bool = idx == 2
	var hazard_phase: bool = idx == 3
	_palette.visible = props_phase
	_tools_title.visible = not props_phase
	_tool_list.visible = not props_phase and not hazard_phase
	_state_title.visible = not props_phase and not hazard_phase
	_state_list.visible = not props_phase and not hazard_phase
	_role_title.visible = not props_phase and not hazard_phase
	_role_scroll.visible = not props_phase and not hazard_phase
	_new_room_btn.visible = not props_phase and not hazard_phase
	if _hazard_title:
		_hazard_title.visible = hazard_phase
	if _hazard_list:
		_hazard_list.visible = hazard_phase
	_lattice.set_slot_overlay_visible(props_phase)
	if props_phase:
		if _lattice.active_tool != _LATTICE.TOOL_PROP:
			_lattice.set_tool(_LATTICE.TOOL_PROP)
		var room: Dictionary = _lattice.get_selected()
		_palette.set_role_filter(str(room.get("role", "")))
		_status.text = "Props: LMB place/select · RMB delete · R rotate · Del remove · reserved (door/vertical) blocked"
	elif assets_phase:
		if _lattice.active_tool != _LATTICE.TOOL_ASSET:
			_lattice.set_tool(_LATTICE.TOOL_ASSET)
		_status.text = "Assign module: click compiled floor/wall/portal · Del removes selected portal/vertical · Esc cancels pending · Q/E deck"
	elif hazard_phase:
		if _lattice.active_tool != _LATTICE.TOOL_HAZARD:
			_lattice.set_tool(_LATTICE.TOOL_HAZARD)
		_highlight_armed_hazard()
		_status.text = "Hazards: LMB two cells or a portal edge · re-click inspects · RMB/Del remove · preview markers only, no live ignite"
	else:
		if _lattice.active_tool == _LATTICE.TOOL_PROP or _lattice.active_tool == _LATTICE.TOOL_ASSET or _lattice.active_tool == _LATTICE.TOOL_HAZARD:
			_lattice.set_tool(_LATTICE.TOOL_PAINT)
		_status.text = "Paint LMB · RMB erase · Portal: click A then neighbor · Vertical: stacked N/N±1 · Assign module: click compiled floor/wall/portal · Hazards: Phase 4 · Del removes selected · Q/E deck"


func _build_tools() -> void:
	var tools := [
		["Paint occupancy", _LATTICE.TOOL_PAINT],
		["Portal / exit", _LATTICE.TOOL_PORTAL],
		["Vertical opening", _LATTICE.TOOL_VERTICAL],
		["Assign module", _LATTICE.TOOL_ASSET],
	]
	for spec in tools:
		var b := Button.new()
		b.text = str(spec[0])
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_tool_pressed.bind(str(spec[1])))
		_tool_list.add_child(b)
	for state in _LATTICE.PORTAL_STATES:
		var sb := Button.new()
		sb.text = state
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb.pressed.connect(_on_portal_state_pressed.bind(state))
		_state_list.add_child(sb)
	_highlight_armed_tool()
	_highlight_armed_state()
	_build_hazard_kinds()


func _on_tool_pressed(tool: String) -> void:
	_lattice.set_tool(tool)
	_highlight_armed_tool()


func _on_portal_state_pressed(state: String) -> void:
	_lattice.stamp_portal_state(state)
	_highlight_armed_state()


func _highlight_armed_tool() -> void:
	var armed := str(_lattice.active_tool)
	var labels := {
		_LATTICE.TOOL_PAINT: "Paint occupancy",
		_LATTICE.TOOL_PORTAL: "Portal / exit",
		_LATTICE.TOOL_VERTICAL: "Vertical opening",
		_LATTICE.TOOL_PROP: "Place prop",
		_LATTICE.TOOL_ASSET: "Assign module",
		_LATTICE.TOOL_HAZARD: "Hazard zone",
	}
	var want := str(labels.get(armed, "Paint occupancy"))
	for child in _tool_list.get_children():
		var b := child as Button
		if b == null:
			continue
		b.modulate = Color(1.15, 1.1, 0.65) if b.text == want else Color.WHITE


func _highlight_armed_state() -> void:
	var armed := str(_lattice.active_portal_state)
	for child in _state_list.get_children():
		var b := child as Button
		if b == null:
			continue
		b.modulate = Color(1.15, 1.1, 0.65) if b.text == armed else Color.WHITE


func _build_hazard_kinds() -> void:
	_hazard_title = Label.new()
	_hazard_title.text = "Hazard kind"
	_hazard_list = VBoxContainer.new()
	_hazard_list.add_theme_constant_override("separation", 4)
	var dock := _tool_list.get_parent()
	var insert_at := _state_list.get_index() + 1
	dock.add_child(_hazard_title)
	dock.move_child(_hazard_title, insert_at)
	dock.add_child(_hazard_list)
	dock.move_child(_hazard_list, insert_at + 1)
	for kind in _LATTICE.HAZARD_KINDS:
		var b := Button.new()
		b.text = _hazard_kind_label(kind)
		b.set_meta("kind", kind)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_hazard_kind_pressed.bind(kind))
		_hazard_list.add_child(b)
	_hazard_title.visible = false
	_hazard_list.visible = false
	_highlight_armed_hazard()


func _hazard_kind_label(kind: String) -> String:
	match kind:
		"timed_fire":
			return "Fire"
		"hull_breach":
			return "Breach"
		"electrical_arc":
			return "Arc"
		"radiation":
			return "Radiation"
		_:
			return kind


func _on_hazard_kind_pressed(kind: String) -> void:
	_lattice.stamp_hazard_kind(kind)
	_highlight_armed_hazard()


func _highlight_armed_hazard() -> void:
	if _hazard_list == null:
		return
	var armed := str(_lattice.active_hazard_kind)
	for child in _hazard_list.get_children():
		var b := child as Button
		if b == null:
			continue
		b.modulate = Color(1.15, 1.1, 0.65) if str(b.get_meta("kind", "")) == armed else Color.WHITE


func _build_roles() -> void:
	for role in _LATTICE.ROLES:
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


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT or what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_on_view_pointer_cancelled()


func _on_view_pointer_cancelled() -> void:
	if _lattice:
		_lattice.cancel_pointer()


func _on_export_pressed() -> void:
	if author == null:
		_status.text = "export failed: DerelictAuthor missing"
		return
	_export_dialog.popup_centered()


func _on_export_dir(dir: String) -> void:
	if author == null:
		_status.text = "export failed: DerelictAuthor missing"
		return
	golden = _golden_from_lattice()
	var kit := str(golden.get("kit_id", "ship_structural_v0"))
	var docs: Dictionary = author.export_playable(golden, kit)
	var err := str(docs.get("error", ""))
	if not err.is_empty():
		_status.text = "export failed: %s" % err.split("\n")[0]
		_show_issues([{"code": "Export", "detail": err}], [])
		return
	var layout := str(docs.get("layout_json", ""))
	var slice := str(docs.get("gameplay_slice_json", ""))
	if layout.is_empty() or slice.is_empty():
		_status.text = "export failed: empty documents"
		return
	var lp := dir.path_join("layout.json")
	var gp := dir.path_join("gameplay_slice.json")
	if not _write_text(lp, layout) or not _write_text(gp, slice):
		return
	_status.text = "exported %s and %s" % [lp, gp]


func _write_text(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status.text = "export failed: cannot write %s" % path
		return false
	f.store_string(text)
	if not text.ends_with("\n"):
		f.store_string("\n")
	return true


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
	_refresh_phases()
	_schedule_compile()


func _on_room_selected(room: Dictionary) -> void:
	_module_sel = {}
	_preview.highlight_selection("", "")
	if room.is_empty():
		_inspector.clear()
		_room_list.deselect_all()
		_palette.set_role_filter("")
		return
	_palette.set_role_filter(str(room.get("role", "")))
	var id := int(room["id"])
	_inspector.bind_room(room, _ensure_vars(id))
	for i in _room_list.item_count:
		if int(_room_list.get_item_metadata(i)) == id:
			_room_list.select(i)
			break


func _on_portal_selected(portal: Dictionary) -> void:
	_module_sel = {}
	_preview.highlight_selection("", "")
	if portal.is_empty():
		_inspector.clear()
		return
	_inspector.bind_portal(portal)
	_highlight_armed_state()
	var id := int(portal.get("from_room", 0))
	for i in _room_list.item_count:
		if int(_room_list.get_item_metadata(i)) == id:
			_room_list.select(i)
			break


func _on_vertical_selected(vertical: Dictionary) -> void:
	_module_sel = {}
	_preview.highlight_selection("", "")
	if vertical.is_empty():
		_inspector.clear()
		return
	_inspector.bind_vertical(vertical)
	var id := int(vertical.get("from_room", 0))
	for i in _room_list.item_count:
		if int(_room_list.get_item_metadata(i)) == id:
			_room_list.select(i)
			break


func _on_prop_selected(prop: Dictionary) -> void:
	_module_sel = {}
	_preview.highlight_selection("", "")
	if prop.is_empty():
		_inspector.clear()
		return
	_inspector.bind_prop(prop)
	var cell: Variant = prop.get("cell", [])
	if cell is Array and (cell as Array).size() >= 3:
		var a: Array = cell
		var room := _room_at(Vector3i(int(a[0]), int(a[1]), int(a[2])))
		if not room.is_empty():
			_palette.set_role_filter(str(room.get("role", "")))


func _on_props_changed() -> void:
	golden = _golden_from_lattice()
	_refresh_prop_preview()


func _on_hazard_selected(zone: Dictionary) -> void:
	_module_sel = {}
	_preview.highlight_selection("", "")
	if zone.is_empty():
		_inspector.clear()
		return
	_inspector.bind_hazard(zone)
	_highlight_armed_hazard()
	var sid := str(zone.get("from_room", ""))
	for i in _room_list.item_count:
		var id := int(_room_list.get_item_metadata(i))
		var room := _room_by_id(id)
		if str(room.get("stable_id", "")) == sid:
			_room_list.select(i)
			break


func _on_hazards_changed() -> void:
	golden = _golden_from_lattice()
	_preview.apply_hazards(_lattice.get_hazards())


func _room_by_id(id: int) -> Dictionary:
	for r in _lattice.get_rooms():
		if int(r.get("id", 0)) == id:
			return r
	return {}


func _room_at(cell: Vector3i) -> Dictionary:
	for r in _lattice.get_rooms():
		if int(r.get("deck", -1)) != cell.z:
			continue
		for c in r.get("cells", []):
			var p: Vector2i = c
			if p.x == cell.x and p.y == cell.y:
				return r
	return {}


func _refresh_prop_preview() -> void:
	_preview.apply_props(_lattice.get_props(), _palettes)


func _on_piece_selected(sel: Dictionary) -> void:
	if sel.is_empty():
		_module_sel = {}
		_preview.highlight_selection("", "")
		_inspector.clear()
		return
	_bind_module_sel(sel)


func _bind_module_sel(sel: Dictionary) -> void:
	var next := _enrich_module_sel(sel)
	_module_sel = next
	var layer := "floor"
	if str(next.get("ov_map", "")) == "ceilings":
		layer = "ceiling"
	elif str(next.get("ov_map", "")) == "edges":
		layer = "edge"
	_preview.highlight_selection(layer, str(next.get("key", "")))
	var legal := PackedStringArray()
	if author != null and str(next.get("kind", "")) != "":
		legal = author.legal_modules(str(next["kind"]), str(next.get("state", "")))
	_inspector.bind_module(next, legal)


func _enrich_module_sel(sel: Dictionary) -> Dictionary:
	var next := sel.duplicate(true)
	var ov_map := str(next.get("ov_map", ""))
	var key := str(next.get("key", ""))
	var ov: Dictionary = _module_overrides.get(ov_map, {})
	var dressed_map: Dictionary = _dressed.get(ov_map, {})
	var current := _plan_module_id(ov_map, key)
	if ov.has(key):
		current = str(ov[key])
	if current.is_empty():
		current = str(next.get("module_id", ""))
	next["module_id"] = current
	next["overridden"] = ov.has(key)
	var dressed := str(dressed_map.get(key, ""))
	if dressed.is_empty():
		dressed = current
	next["dressed_id"] = dressed
	if ov_map == "edges":
		var edge := _plan_edge(key)
		var edge_state := str(edge.get("state", edge.get("kind", next.get("state", "SOLID"))))
		if str(next.get("kind", "")) != "portal":
			var vk := _vertex_state(dressed)
			if vk.is_empty() and not next.get("overridden", false):
				vk = _vertex_state(current)
			if not vk.is_empty():
				next["kind"] = "vertex"
				next["state"] = vk
			else:
				next["kind"] = "wall"
				next["state"] = "SOLID"
		else:
			next["state"] = str(next.get("state", edge_state))
	if ov_map == "floors":
		var role := str(next.get("role", next.get("state", "")))
		next["kind"] = "floor"
		next["state"] = role
		var cell := _cell3_from_key(key)
		var ceil := {
			"ov_map": "ceilings",
			"kind": "ceiling",
			"state": "",
			"key": key,
			"cell": next.get("cell", cell),
			"role": role,
			"alt_label": "Inspect floor",
			"alt": {
				"ov_map": "floors",
				"kind": "floor",
				"state": role,
				"key": key,
				"cell": next.get("cell", cell),
				"role": role,
			},
		}
		next["alt_label"] = "Inspect ceiling"
		next["alt"] = ceil
	elif ov_map == "ceilings":
		var role := str(next.get("role", ""))
		next["kind"] = "ceiling"
		next["state"] = ""
		var cell := next.get("cell", _cell3_from_key(key))
		next["alt_label"] = "Inspect floor"
		next["alt"] = {
			"ov_map": "floors",
			"kind": "floor",
			"state": role,
			"key": key,
			"cell": cell,
			"role": role,
		}
		if _lattice.has_vertical_at_key(key):
			next["note"] = "Ceiling is suppressed on this vertical opening."
			next["assignable"] = false
	var preferred := PackedStringArray()
	if author != null:
		preferred = author.legal_modules(str(next.get("kind", "")), str(next.get("state", "")))
	if not preferred.is_empty():
		next["default_id"] = preferred[0]
	return next


func _vertex_state(module_id: String) -> String:
	match module_id:
		"wall_inner_corner":
			return "inner"
		"wall_outer_corner":
			return "outer"
		"wall_t_junction":
			return "t"
		_:
			return ""


func _plan_module_id(ov_map: String, key: String) -> String:
	if ov_map == "floors":
		for rec_v in _last_plan.get("floor_placements", []):
			if rec_v is Dictionary and str(rec_v.get("cell_key", "")) == key:
				return str(rec_v.get("module_id", ""))
		var occ: Variant = _last_plan.get("occupancy", {})
		if occ is Dictionary and (occ as Dictionary).has(key):
			var rec: Variant = occ[key]
			if rec is Dictionary:
				return str(rec.get("module_id", ""))
	elif ov_map == "ceilings":
		for rec_v in _last_plan.get("ceiling_placements", []):
			if rec_v is Dictionary and str(rec_v.get("cell_key", "")) == key:
				return str(rec_v.get("module_id", ""))
	elif ov_map == "edges":
		var edge := _plan_edge(key)
		return str(edge.get("module_id", ""))
	return ""


func _plan_edge(key: String) -> Dictionary:
	var edges: Variant = _last_plan.get("edges", {})
	if edges is Dictionary and (edges as Dictionary).has(key):
		var rec: Variant = edges[key]
		if rec is Dictionary:
			return rec
	for rec_v in _last_plan.get("placements", []):
		if rec_v is Dictionary:
			var rec: Dictionary = rec_v
			if str(rec.get("edge_key", rec.get("key", ""))) == key:
				return rec
	return {}


func _cell3_from_key(key: String) -> Array:
	var parts := key.split("|")
	if parts.size() != 3:
		return [0, 0, 0]
	return [int(parts[1]), int(parts[2]), int(parts[0])]


func _on_module_override_set(ov_map: String, key: String, module_id: String) -> void:
	if ov_map != "floors" and ov_map != "ceilings" and ov_map != "edges":
		return
	if key.is_empty() or module_id.is_empty():
		return
	if ov_map == "ceilings" and _lattice.has_vertical_at_key(key):
		return
	if not _module_overrides.has(ov_map) or not (_module_overrides[ov_map] is Dictionary):
		_module_overrides[ov_map] = {}
	(_module_overrides[ov_map] as Dictionary)[key] = module_id
	if ov_map == "edges":
		var edge := _plan_edge(key)
		_edge_override_kinds[key] = str(edge.get("kind", edge.get("state", "")))
	if not _module_sel.is_empty():
		_module_sel["module_id"] = module_id
		_module_sel["overridden"] = true
	_schedule_compile()


func _on_tool_changed(_t: String) -> void:
	_highlight_armed_tool()
	if _lattice.active_tool == _LATTICE.TOOL_ASSET:
		if _phase_bar.current_tab != 2 and not _phase_bar.is_tab_disabled(2):
			_phase_bar.set_block_signals(true)
			_phase_bar.current_tab = 2
			_phase_bar.set_block_signals(false)
			_apply_phase(2)
	elif _lattice.active_tool == _LATTICE.TOOL_PROP:
		if _phase_bar.current_tab != 1 and not _phase_bar.is_tab_disabled(1):
			_phase_bar.set_block_signals(true)
			_phase_bar.current_tab = 1
			_phase_bar.set_block_signals(false)
			_apply_phase(1)
	elif _lattice.active_tool == _LATTICE.TOOL_HAZARD:
		if _phase_bar.current_tab != 3 and not _phase_bar.is_tab_disabled(3):
			_phase_bar.set_block_signals(true)
			_phase_bar.current_tab = 3
			_phase_bar.set_block_signals(false)
			_apply_phase(3)
	elif _phase_bar.current_tab == 2 or _phase_bar.current_tab == 1 or _phase_bar.current_tab == 3:
		_phase_bar.set_block_signals(true)
		_phase_bar.current_tab = 0
		_phase_bar.set_block_signals(false)
		_apply_phase(0)


func _refresh_phases() -> void:
	var has_occ := not _lattice.get_rooms().is_empty()
	_phase_bar.set_tab_disabled(2, not has_occ)
	if not has_occ and _phase_bar.current_tab == 2:
		_phase_bar.current_tab = 0
		_apply_phase(0)


func _on_portal_edited(portal: Dictionary) -> void:
	_lattice.apply_portal_edit(portal)
	_highlight_armed_state()


func _on_room_edited(room: Dictionary, vars: Dictionary) -> void:
	var id := int(room.get("id", 0))
	_room_vars[str(id)] = vars
	_lattice.apply_room_edit(room)
	_palette.set_role_filter(str(room.get("role", "")))
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


func _on_deck_changed(_d: int) -> void:
	_preview.set_active_deck(_lattice.active_deck)
	_sync_deck_label()


func _sync_deck_label() -> void:
	_deck_label.text = "Deck %d / %d" % [_lattice.active_deck, _lattice.deck_count - 1]


func _resolve_content() -> void:
	if author == null:
		_content_offline = true
		_banner.visible = true
		_banner_label.text = "DerelictAuthor missing. Run scripts/build_windows.ps1 -Builder."
		_root_label.text = "content root: (extension missing)"
		_preview.configure("", true)
		_bind_palettes()
		return
	var info: Dictionary = _content.resolve()
	_content_offline = bool(info.get("offline", true))
	_banner.visible = _content_offline
	if _content_offline:
		_banner_label.text = "Offline: no Synaptic Sea content root — palettes from embedded RON, CSG preview only."
		_root_label.text = "content root: (offline)"
		author.set_content_root("")
		_preview.configure("", true)
		_bind_palettes()
		return
	var path := str(info.get("path", ""))
	_root_label.text = "content root: %s (%s)" % [path, info.get("source", "")]
	_preview.configure(path, false)
	var result: Dictionary = author.set_content_root(path)
	if not bool(result.get("ok", false)):
		_banner.visible = true
		var errs: Array = result.get("errors", [])
		var msg := "Content root loaded with errors"
		if not errs.is_empty():
			msg += ": " + str(errs[0])
		_banner_label.text = msg
	_bind_palettes()


func _bind_palettes() -> void:
	if author == null:
		_palettes = {}
		_palette.bind_palettes({})
		_inspector.bind_palettes({})
		return
	_palettes = author.palettes()
	_palette.bind_palettes(_palettes)
	_inspector.bind_palettes(_palettes)


func _schedule_compile() -> void:
	golden = _golden_from_lattice()
	_compile_timer.start(COMPILE_DEBOUNCE_S)


func _run_compile() -> void:
	if author == null:
		_show_issues([{"code": "Extension", "detail": "DerelictAuthor missing. Run scripts/build_windows.ps1 -Builder."}], [])
		_preview.apply_plan({})
		_preview.apply_props([], _palettes)
		_preview.apply_hazards(_lattice.get_hazards())
		_lattice.set_compile_result({}, {}, false)
		_lattice.set_occupancy_floors_visible(true)
		_set_phase2_ready(false)
		return
	var result: Dictionary = author.compile(golden)
	if result.has("error"):
		_show_issues([{"code": "Compile", "detail": str(result["error"])}], [])
		_preview.apply_plan({})
		_preview.apply_props([], _palettes)
		_preview.apply_hazards(_lattice.get_hazards())
		_lattice.set_compile_result({}, {}, false)
		_lattice.set_occupancy_floors_visible(true)
		_set_phase2_ready(false)
		return
	var issues: Array = result.get("issues", [])
	var stale: Array = result.get("stale_overrides", [])
	_show_issues(issues, stale)
	var plan: Dictionary = result.get("plan", {})
	var zones: Dictionary = result.get("zones", {})
	var occupancy_ok: bool = not _lattice.get_rooms().is_empty()
	var ok: bool = issues.is_empty() and occupancy_ok
	_lattice.set_compile_result(zones, plan, ok)
	_last_plan = plan
	if _prune_stale_module_overrides():
		golden = _golden_from_lattice()
		_schedule_compile()
		return
	_capture_dressed(plan)
	_preview.set_active_deck(_lattice.active_deck)
	_preview.apply_plan(plan)
	_preview.apply_props(_lattice.get_props(), _palettes)
	_preview.apply_hazards(_lattice.get_hazards())
	# Hide occupancy CSG floors only when every occupied cell has a floor GLB.
	_lattice.set_occupancy_floors_visible(not _preview.covers_occupied_floors())
	if issues.is_empty() and stale.is_empty() and _issues.item_count > 0:
		_issues.set_item_text(0, "Compile OK · %s" % _preview.status_text())
	else:
		_issues.add_item(_preview.status_text())
	_apply_preview_banner()
	_set_phase2_ready(ok)
	if not _module_sel.is_empty():
		_bind_module_sel(_module_sel)


func _set_phase2_ready(ok: bool) -> void:
	_compile_ok = ok
	_phase_bar.set_tab_disabled(1, not ok)
	if not ok and _phase_bar.current_tab == 1:
		_phase_bar.current_tab = 0
		_apply_phase(0)
	elif ok and _phase_bar.current_tab == 1:
		_lattice.set_slot_overlay_visible(true)


func _show_issues(issues: Array, stale: Array = []) -> void:
	_issues.clear()
	if issues.is_empty() and stale.is_empty():
		_issues.add_item("Compile OK")
		return
	for iss in issues:
		if iss is Dictionary:
			_issues.add_item("%s: %s" % [iss.get("code", "?"), iss.get("detail", "")])
		else:
			_issues.add_item(str(iss))
	for s in stale:
		if s is Dictionary:
			_issues.add_item("stale_override: %s %s → %s" % [
				s.get("class", "?"), s.get("key", ""), s.get("module_id", "")
			])
		else:
			_issues.add_item(str(s))


func _apply_preview_banner() -> void:
	if author == null or _content_offline:
		return
	var root_errors := _banner_label.text.begins_with("Content root loaded with errors")
	if _preview.claimed_kit_preview:
		if root_errors:
			return
		_banner.visible = false
		return
	if _preview.fallback_count == 0:
		return
	if root_errors:
		return
	_banner.visible = true
	_banner_label.text = "CSG fallback: %s. Not claiming kit preview." % _preview.status_text()


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
	var portals: Array = _lattice.get_portals()
	for p in portals:
		if p is Dictionary:
			(p as Dictionary).erase("module_id")
	g["topology"] = {
		"rooms": rooms,
		"portals": portals,
		"verticals": _lattice.get_verticals(),
	}
	g["room_vars"] = _room_vars.duplicate(true)
	g["hazards"] = _lattice.get_hazards_dto()
	var props: Array = []
	for p in _lattice.get_props():
		if str(p.get("kind", "")) == "Door":
			continue
		props.append(p)
	g["props"] = props
	g["module_overrides"] = {
		"floors": (_module_overrides.get("floors", {}) as Dictionary).duplicate(true),
		"ceilings": (_module_overrides.get("ceilings", {}) as Dictionary).duplicate(true),
		"edges": (_module_overrides.get("edges", {}) as Dictionary).duplicate(true),
	}
	return g


func _prune_stale_module_overrides() -> bool:
	var dirty := false
	var ceil: Dictionary = _module_overrides.get("ceilings", {})
	for key in ceil.keys():
		if _lattice.has_vertical_at_key(str(key)):
			ceil.erase(key)
			dirty = true
	var ov: Dictionary = _module_overrides.get("edges", {})
	for key in ov.keys():
		var rec := _plan_edge(str(key))
		if rec.is_empty():
			ov.erase(key)
			_edge_override_kinds.erase(key)
			dirty = true
			continue
		var kind := str(rec.get("kind", rec.get("state", "")))
		var remembered := str(_edge_override_kinds.get(key, ""))
		if remembered != "" and remembered != kind:
			ov.erase(key)
			_edge_override_kinds.erase(key)
			dirty = true
	return dirty


func _capture_dressed(plan: Dictionary) -> void:
	_capture_dressed_layer("floors", plan.get("floor_placements", []), "cell_key")
	_capture_dressed_layer("ceilings", plan.get("ceiling_placements", []), "cell_key")
	var edge_items: Array = []
	var edges: Variant = plan.get("edges", {})
	if edges is Dictionary:
		for k in edges:
			var rec: Variant = edges[k]
			if rec is Dictionary:
				var d: Dictionary = (rec as Dictionary).duplicate(true)
				d["edge_key"] = str(k)
				edge_items.append(d)
	elif edges is Array:
		edge_items = edges
	if edge_items.is_empty():
		edge_items = plan.get("placements", [])
	_capture_dressed_layer("edges", edge_items, "edge_key")


func _capture_dressed_layer(ov_map: String, items: Variant, key_field: String) -> void:
	if not (items is Array):
		return
	var ov: Dictionary = _module_overrides.get(ov_map, {})
	var dressed: Dictionary = _dressed.get(ov_map, {})
	var live: Dictionary = {}
	for rec_v in items:
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var key := str(rec.get(key_field, rec.get("key", rec.get("cell_key", ""))))
		if key.is_empty():
			continue
		if ov.has(key):
			live[key] = str(dressed.get(key, rec.get("module_id", "")))
		else:
			live[key] = str(rec.get("module_id", ""))
	_dressed[ov_map] = live
