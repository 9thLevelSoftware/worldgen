class_name InspectorDock
extends VBoxContainer
## Selected room, portal, vertical, prop, compiled module, or hazard inspector.

const _LATTICE := preload("res://scripts/OccupancyLattice.gd")

## validate.rs FLOOR_MODULES. Anything else on a floor is greyed + FloorBadModule.
const FLOOR_MODULES: PackedStringArray = ["floor_1x1", "corridor_floor_1x1"]
const GREYED_FLOOR_MODULES: PackedStringArray = [
	"floor_2x1", "corridor_floor_1x2", "ramp_up_1x2", "pillar_support_1x1",
]
const HATCH_NOTE := "visual mismatch, legal id"
const VERTEX_INNER := "wall_inner_corner"
const VERTEX_OUTER := "wall_outer_corner"
const VERTEX_T := "wall_t_junction"

signal room_edited(room: Dictionary, vars: Dictionary)
signal portal_edited(portal: Dictionary)
signal portal_removed
signal vertical_removed
signal prop_edited(prop: Dictionary)
signal prop_removed
signal module_override_set(ov_map: String, key: String, module_id: String)
signal module_inspect_requested(sel: Dictionary)
signal hazard_edited(zone: Dictionary)
signal hazard_removed

var _syncing := false
var _room: Dictionary = {}
var _vars: Dictionary = {}
var _portal: Dictionary = {}
var _vertical: Dictionary = {}
var _prop: Dictionary = {}
var _hazard: Dictionary = {}
var _fields: VBoxContainer
var _portal_fields: VBoxContainer
var _vert_fields: VBoxContainer
var _prop_fields: VBoxContainer
var _hazard_fields: VBoxContainer

var _id_label: Label
var _stable: LineEdit
var _role: OptionButton
var _deck: Label
var _cells: Label
var _oxygen: SpinBox
var _depress: CheckBox
var _vented: CheckBox
var _rad: SpinBox
var _temp: SpinBox
var _notes: LineEdit
var _empty: Label

var _p_from: Label
var _p_to: Label
var _p_cells: Label
var _p_ext: Label
var _p_state: OptionButton
var _p_note: Label
var _p_remove: Button

var _v_from: Label
var _v_to: Label
var _v_cells: Label
var _v_note: Label
var _v_remove: Button

var _pr_id: Label
var _pr_kind: Label
var _pr_proto: Label
var _pr_visual: Label
var _pr_cell: Label
var _pr_rot: Label
var _pr_facing: Label
var _pr_locked: CheckBox
var _pr_note: Label
var _pr_remove: Button
var _atm_note: Label
var _cid_label: Label

var _h_id: Label
var _h_kind: Label
var _h_from: Label
var _h_to: Label
var _h_cells: Label
var _h_cid: Label
var _h_module: LineEdit
var _h_rationale: LineEdit
var _h_note: Label
var _h_remove: Button

var _mod_fields: VBoxContainer
var _mod_kind: Label
var _mod_key: Label
var _mod_current: Label
var _mod_default: Label
var _mod_note: Label
var _mod_list: ItemList
var _mod_grey_note: Label
var _mod_alt: Button
var _mod_sel: Dictionary = {}
var _mod_ids: PackedStringArray = PackedStringArray()


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "Inspector"
	title.theme_type_variation = "HeaderSmall"
	add_child(title)

	_empty = Label.new()
	_empty.text = "Room list: inspect only. Paint: occupied click stamps+selects (re-click inspects). Portal: click A then a cardinal neighbor. Vertical: stacked occupied cells on N and N±1. Props: snap to compiled wall/center slots after compile OK. Assign module: click a compiled floor, wall, or portal. Hazards: click two cells or a portal edge (re-click inspects). Delete removes the selected portal, vertical, prop, or hazard."
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_empty)

	_fields = VBoxContainer.new()
	_fields.add_theme_constant_override("separation", 6)
	add_child(_fields)

	_id_label = _ro_line("Room id")
	_stable = _edit_line("stable_id")
	_stable.text_submitted.connect(func(_t: String) -> void: _emit())
	_stable.focus_exited.connect(_emit)
	_role = OptionButton.new()
	for r in _LATTICE.ROLES:
		_role.add_item(r)
	_role.item_selected.connect(func(_i: int) -> void: _emit())
	_labeled("role", _role)
	_deck = _ro_line("deck")
	_cells = _ro_line("cells")
	_cells.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var vars_title := Label.new()
	vars_title.text = "Room vars"
	vars_title.theme_type_variation = "HeaderSmall"
	_fields.add_child(vars_title)

	var atm := Label.new()
	atm.text = "Compartment atmosphere (bp) — not player tank"
	atm.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fields.add_child(atm)
	_oxygen = _spin("oxygen_bp", 0, 65535, 8500)
	_depress = _check("depressurized")
	_vented = _check("vented")
	_rad = _spin("radiation_bp", 0, 65535, 0)
	_temp = _spin("temperature_c", -273, 500, 18)
	_cid_label = _ro_line("compartment")
	_notes = _edit_line("notes")
	_notes.text_submitted.connect(func(_t: String) -> void: _emit())
	_notes.focus_exited.connect(_emit)
	_atm_note = Label.new()
	_atm_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_atm_note.modulate = Color(0.85, 0.85, 0.7)
	_fields.add_child(_atm_note)

	_fields.visible = false

	_portal_fields = VBoxContainer.new()
	_portal_fields.add_theme_constant_override("separation", 6)
	add_child(_portal_fields)
	var ptitle := Label.new()
	ptitle.text = "Portal"
	ptitle.theme_type_variation = "HeaderSmall"
	_portal_fields.add_child(ptitle)
	_p_from = _ro_line_in(_portal_fields, "from_room")
	_p_to = _ro_line_in(_portal_fields, "to_room")
	_p_cells = _ro_line_in(_portal_fields, "cells")
	_p_cells.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_p_ext = _ro_line_in(_portal_fields, "exterior")
	_p_state = OptionButton.new()
	for s in _LATTICE.PORTAL_STATES:
		_p_state.add_item(s)
	_p_state.item_selected.connect(func(_i: int) -> void: _emit_portal())
	_labeled_in(_portal_fields, "state", _p_state)
	_p_note = Label.new()
	_p_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_p_note.modulate = Color(0.85, 0.85, 0.7)
	_portal_fields.add_child(_p_note)
	_p_remove = Button.new()
	_p_remove.text = "Remove portal"
	_p_remove.pressed.connect(func() -> void: portal_removed.emit())
	_portal_fields.add_child(_p_remove)
	_portal_fields.visible = false

	_vert_fields = VBoxContainer.new()
	_vert_fields.add_theme_constant_override("separation", 6)
	add_child(_vert_fields)
	var vtitle := Label.new()
	vtitle.text = "Vertical opening"
	vtitle.theme_type_variation = "HeaderSmall"
	_vert_fields.add_child(vtitle)
	_v_from = _ro_line_in(_vert_fields, "from_room")
	_v_to = _ro_line_in(_vert_fields, "to_room")
	_v_cells = _ro_line_in(_vert_fields, "cells")
	_v_cells.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_v_note = Label.new()
	_v_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_v_note.modulate = Color(0.85, 0.85, 0.7)
	_vert_fields.add_child(_v_note)
	_v_remove = Button.new()
	_v_remove.text = "Remove vertical"
	_v_remove.pressed.connect(func() -> void: vertical_removed.emit())
	_vert_fields.add_child(_v_remove)
	_vert_fields.visible = false

	_prop_fields = VBoxContainer.new()
	_prop_fields.add_theme_constant_override("separation", 6)
	add_child(_prop_fields)
	var prtitle := Label.new()
	prtitle.text = "Prop"
	prtitle.theme_type_variation = "HeaderSmall"
	_prop_fields.add_child(prtitle)
	_pr_id = _ro_line_in(_prop_fields, "id")
	_pr_kind = _ro_line_in(_prop_fields, "kind")
	_pr_proto = _ro_line_in(_prop_fields, "proto")
	_pr_visual = _ro_line_in(_prop_fields, "visual_id")
	_pr_cell = _ro_line_in(_prop_fields, "cell")
	_pr_rot = _ro_line_in(_prop_fields, "rotation")
	_pr_facing = _ro_line_in(_prop_fields, "facing")
	_pr_locked = CheckBox.new()
	_pr_locked.text = "locked"
	_pr_locked.toggled.connect(func(_v: bool) -> void: _emit_prop())
	_prop_fields.add_child(_pr_locked)
	_pr_note = Label.new()
	_pr_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pr_note.modulate = Color(0.85, 0.85, 0.7)
	_prop_fields.add_child(_pr_note)
	_pr_remove = Button.new()
	_pr_remove.text = "Remove prop"
	_pr_remove.pressed.connect(func() -> void: prop_removed.emit())
	_prop_fields.add_child(_pr_remove)
	_prop_fields.visible = false

	_mod_fields = VBoxContainer.new()
	_mod_fields.add_theme_constant_override("separation", 6)
	add_child(_mod_fields)
	var mtitle := Label.new()
	mtitle.text = "Module"
	mtitle.theme_type_variation = "HeaderSmall"
	_mod_fields.add_child(mtitle)
	_mod_kind = _ro_line_in(_mod_fields, "selection")
	_mod_key = _ro_line_in(_mod_fields, "key")
	_mod_current = _ro_line_in(_mod_fields, "current")
	_mod_default = _ro_line_in(_mod_fields, "default")
	_mod_note = Label.new()
	_mod_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mod_note.modulate = Color(0.85, 0.85, 0.7)
	_mod_fields.add_child(_mod_note)
	_mod_list = ItemList.new()
	_mod_list.custom_minimum_size = Vector2(0, 180)
	_mod_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mod_list.allow_reselect = true
	_mod_list.item_selected.connect(_on_module_item_selected)
	_mod_fields.add_child(_mod_list)
	_mod_grey_note = Label.new()
	_mod_grey_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mod_grey_note.modulate = Color(0.7, 0.7, 0.72)
	_mod_grey_note.visible = false
	_mod_fields.add_child(_mod_grey_note)
	_mod_alt = Button.new()
	_mod_alt.visible = false
	_mod_alt.pressed.connect(_on_mod_alt)
	_mod_fields.add_child(_mod_alt)
	_mod_fields.visible = false

	_hazard_fields = VBoxContainer.new()
	_hazard_fields.add_theme_constant_override("separation", 6)
	add_child(_hazard_fields)
	var htitle := Label.new()
	htitle.text = "Hazard zone"
	htitle.theme_type_variation = "HeaderSmall"
	_hazard_fields.add_child(htitle)
	_h_id = _ro_line_in(_hazard_fields, "id")
	_h_kind = _ro_line_in(_hazard_fields, "kind")
	_h_from = _ro_line_in(_hazard_fields, "from_room")
	_h_to = _ro_line_in(_hazard_fields, "to_room")
	_h_cells = _ro_line_in(_hazard_fields, "cells")
	_h_cells.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_h_cid = _ro_line_in(_hazard_fields, "compartment")
	_h_module = LineEdit.new()
	_h_module.placeholder_text = "optional"
	_h_module.text_submitted.connect(func(_t: String) -> void: _emit_hazard())
	_h_module.focus_exited.connect(_emit_hazard)
	_labeled_in(_hazard_fields, "module_id", _h_module)
	_h_rationale = LineEdit.new()
	_h_rationale.text_submitted.connect(func(_t: String) -> void: _emit_hazard())
	_h_rationale.focus_exited.connect(_emit_hazard)
	_labeled_in(_hazard_fields, "rationale", _h_rationale)
	_h_note = Label.new()
	_h_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_h_note.modulate = Color(0.85, 0.85, 0.7)
	_hazard_fields.add_child(_h_note)
	_h_remove = Button.new()
	_h_remove.text = "Remove hazard"
	_h_remove.pressed.connect(func() -> void: hazard_removed.emit())
	_hazard_fields.add_child(_h_remove)
	_hazard_fields.visible = false


func bind_room(room: Dictionary, vars: Dictionary) -> void:
	_room = room
	_vars = vars.duplicate(true)
	_portal = {}
	_vertical = {}
	_prop = {}
	_mod_sel = {}
	_hazard = {}
	_portal_fields.visible = false
	_vert_fields.visible = false
	_prop_fields.visible = false
	_mod_fields.visible = false
	_hazard_fields.visible = false
	if room.is_empty():
		_empty.visible = true
		_fields.visible = false
		return
	_empty.visible = false
	_fields.visible = true
	_syncing = true
	_id_label.text = str(int(room.get("id", 0)))
	_stable.text = str(room.get("stable_id", ""))
	var role := str(room.get("role", "compartment"))
	var idx := _LATTICE.ROLES.find(role)
	_role.select(idx if idx >= 0 else _LATTICE.ROLES.find("compartment"))
	_deck.text = str(int(room.get("deck", 0)))
	_cells.text = _format_cells(room.get("cells", []))
	_oxygen.set_value_no_signal(int(vars.get("oxygen_bp", 8500)))
	_depress.set_pressed_no_signal(bool(vars.get("depressurized", false)))
	_rad.set_value_no_signal(int(vars.get("radiation_bp", 0)))
	_temp.set_value_no_signal(int(vars.get("temperature_c", 18)))
	_notes.text = str(vars.get("notes", ""))
	_apply_atmosphere_honesty(role, vars)
	_syncing = false
	if _LATTICE.compartment_for_role(role).is_empty() and bool(vars.get("vented", false)):
		_emit()


func bind_portal(portal: Dictionary) -> void:
	_portal = portal.duplicate(true)
	_room = {}
	_vertical = {}
	_prop = {}
	_mod_sel = {}
	_hazard = {}
	_fields.visible = false
	_vert_fields.visible = false
	_prop_fields.visible = false
	_mod_fields.visible = false
	_hazard_fields.visible = false
	if portal.is_empty():
		_portal_fields.visible = false
		_empty.visible = true
		return
	_empty.visible = false
	_portal_fields.visible = true
	_syncing = true
	_p_from.text = str(int(portal.get("from_room", 0)))
	_p_to.text = str(int(portal.get("to_room", 0)))
	_p_cells.text = "%s → %s" % [
		_format_xyz(portal.get("from_cell", [])),
		_format_xyz(portal.get("to_cell", [])),
	]
	var exterior := bool(portal.get("exterior", false))
	_p_ext.text = "true" if exterior else "false"
	var state := str(portal.get("state", "DOOR"))
	var idx := _LATTICE.PORTAL_STATES.find(state)
	_p_state.select(idx if idx >= 0 else 0)
	if state == "BREACH":
		_p_note.text = "BREACH compiles with an empty module_id (no doorway mesh)."
	else:
		_p_note.text = "Doorway module follows this state at compile."
	_syncing = false


func bind_vertical(vertical: Dictionary) -> void:
	_vertical = vertical.duplicate(true)
	_room = {}
	_portal = {}
	_prop = {}
	_mod_sel = {}
	_hazard = {}
	_fields.visible = false
	_portal_fields.visible = false
	_prop_fields.visible = false
	_mod_fields.visible = false
	_hazard_fields.visible = false
	if vertical.is_empty():
		_vert_fields.visible = false
		_empty.visible = true
		return
	_empty.visible = false
	_vert_fields.visible = true
	_syncing = true
	_v_from.text = str(int(vertical.get("from_room", 0)))
	_v_to.text = str(int(vertical.get("to_room", 0)))
	_v_cells.text = "%s ↔ %s" % [
		_format_xyz(vertical.get("from_cell", [])),
		_format_xyz(vertical.get("to_cell", [])),
	]
	_v_note.text = "Ceiling is suppressed on %s and %s." % [
		_cell_key(vertical.get("from_cell", [])),
		_cell_key(vertical.get("to_cell", [])),
	]
	_syncing = false


func bind_prop(prop: Dictionary) -> void:
	_prop = prop.duplicate(true)
	_room = {}
	_portal = {}
	_vertical = {}
	_mod_sel = {}
	_hazard = {}
	_fields.visible = false
	_portal_fields.visible = false
	_vert_fields.visible = false
	_mod_fields.visible = false
	_hazard_fields.visible = false
	if prop.is_empty():
		_prop_fields.visible = false
		_empty.visible = true
		return
	_empty.visible = false
	_prop_fields.visible = true
	_syncing = true
	_pr_id.text = str(int(prop.get("id", 0)))
	_pr_kind.text = str(prop.get("kind", ""))
	_pr_proto.text = str(prop.get("proto", ""))
	_pr_visual.text = str(prop.get("visual_id", ""))
	_pr_cell.text = _format_xyz(prop.get("cell", []))
	_pr_rot.text = str(int(prop.get("rotation", 0)))
	var facing: Variant = prop.get("facing", null)
	_pr_facing.text = str(facing) if facing != null and str(facing) != "" else "—"
	_pr_locked.set_pressed_no_signal(bool(prop.get("locked", false)))
	if str(prop.get("proto", "")) == "bunk" or bool(prop.get("stand_in", false)):
		_pr_note.text = "preview stand-in: bunk → generic_locker (no bunk GLB)."
	else:
		_pr_note.text = "R cycles rotation 0..=3. Doors/ladders are not painted."
	_syncing = false


func bind_hazard(zone: Dictionary) -> void:
	_hazard = zone.duplicate(true)
	_room = {}
	_portal = {}
	_vertical = {}
	_prop = {}
	_mod_sel = {}
	if _fields == null or _hazard_fields == null:
		return
	_fields.visible = false
	_portal_fields.visible = false
	_vert_fields.visible = false
	_prop_fields.visible = false
	if _mod_fields:
		_mod_fields.visible = false
	if zone.is_empty():
		_hazard_fields.visible = false
		_empty.visible = true
		return
	_empty.visible = false
	_hazard_fields.visible = true
	_syncing = true
	_h_id.text = str(zone.get("id", ""))
	_h_kind.text = str(zone.get("kind", ""))
	_h_from.text = str(zone.get("from_room", ""))
	_h_to.text = str(zone.get("to_room", ""))
	_h_cells.text = "%s → %s" % [
		_format_xyz(zone.get("from_cell", [])),
		_format_xyz(zone.get("to_cell", [])),
	]
	var cid := str(zone.get("compartment_id", ""))
	_h_cid.text = cid if cid != "" else "—"
	_h_module.text = str(zone.get("module_id", ""))
	_h_rationale.text = str(zone.get("rationale", ""))
	_h_note.text = _hazard_honesty(cid)
	_syncing = false


func hazard_honesty_text(compartment_id: String) -> String:
	return _hazard_honesty(compartment_id)


func atmosphere_honesty_text(role: String) -> String:
	return _atmosphere_honesty(role)


func clear() -> void:
	bind_room({}, {})


func bind_module(sel: Dictionary, legal: PackedStringArray) -> void:
	_mod_sel = sel.duplicate(true)
	_room = {}
	_portal = {}
	_vertical = {}
	_prop = {}
	_hazard = {}
	_fields.visible = false
	_portal_fields.visible = false
	_vert_fields.visible = false
	_prop_fields.visible = false
	if _hazard_fields:
		_hazard_fields.visible = false
	if sel.is_empty():
		_mod_fields.visible = false
		_empty.visible = true
		return
	_empty.visible = false
	_mod_fields.visible = true
	_syncing = true
	var kind := str(sel.get("kind", ""))
	var state := str(sel.get("state", ""))
	_mod_kind.text = selection_caption(kind, state)
	_mod_key.text = str(sel.get("key", ""))
	var current := str(sel.get("module_id", ""))
	_mod_current.text = current if not current.is_empty() else "(none)"
	_mod_ids = merge_legal_ids(kind, legal, current)
	var preferred := str(sel.get("default_id", ""))
	if preferred.is_empty() and not _mod_ids.is_empty():
		preferred = _mod_ids[0]
	_mod_default.text = preferred if not preferred.is_empty() else "—"
	_mod_note.text = module_note(sel)
	_mod_note.visible = not _mod_note.text.is_empty()
	_fill_module_list(kind, current)
	var assignable := bool(sel.get("assignable", true))
	_mod_list.mouse_filter = Control.MOUSE_FILTER_IGNORE if not assignable else Control.MOUSE_FILTER_STOP
	if not assignable:
		_mod_note.text = module_note(sel)
		_mod_note.visible = true
	_mod_grey_note.visible = kind == "floor"
	if _mod_grey_note.visible:
		_mod_grey_note.text = "Greyed ids are not in FLOOR_MODULES. Assigning writes the override so the GLB preview updates; validate returns FloorBadModule and export is refused."
	var alt := str(sel.get("alt_label", ""))
	_mod_alt.visible = not alt.is_empty()
	_mod_alt.text = alt if not alt.is_empty() else ""
	_syncing = false


func has_module_selection() -> bool:
	return not _mod_sel.is_empty()


func module_selection() -> Dictionary:
	return _mod_sel.duplicate(true)


static func is_greyed_floor(module_id: String) -> bool:
	return FLOOR_MODULES.find(module_id) < 0


static func merge_legal_ids(kind: String, legal: PackedStringArray, current: String) -> PackedStringArray:
	var out := PackedStringArray()
	var seen: Dictionary = {}
	for id in legal:
		var s := str(id)
		if s.is_empty() or seen.has(s):
			continue
		seen[s] = true
		out.append(s)
	if kind == "floor":
		for id in GREYED_FLOOR_MODULES:
			if seen.has(id):
				continue
			seen[id] = true
			out.append(id)
	if not current.is_empty() and not seen.has(current):
		out.append(current)
	return out


static func module_note(sel: Dictionary) -> String:
	var notes: PackedStringArray = PackedStringArray()
	var kind := str(sel.get("kind", ""))
	var state := str(sel.get("state", "")).to_upper()
	if kind == "portal" and state == "HATCH":
		notes.append(HATCH_NOTE)
	if kind == "portal" and state == "BREACH":
		notes.append("BREACH compiles with an empty module_id (no doorway mesh).")
	var dressed := str(sel.get("dressed_id", ""))
	var current := str(sel.get("module_id", ""))
	var overridden := bool(sel.get("overridden", false))
	if kind == "vertex" and overridden and not dressed.is_empty() and dressed != current:
		notes.append("override disagrees with vertex-dressed %s" % dressed)
	var extra := str(sel.get("note", ""))
	if not extra.is_empty():
		notes.append(extra)
	return "\n".join(notes)


static func selection_caption(kind: String, state: String) -> String:
	match kind:
		"floor":
			return "Floor (%s)" % (state if not state.is_empty() else "cell")
		"ceiling":
			return "Ceiling"
		"wall":
			return "Solid wall"
		"portal":
			return "Portal %s" % (state if not state.is_empty() else "DOOR")
		"vertex":
			return "Vertex %s" % (state if not state.is_empty() else "")
		_:
			return kind


func _fill_module_list(kind: String, current: String) -> void:
	_mod_list.clear()
	var select := -1
	for id in _mod_ids:
		var label := id
		var greyed := kind == "floor" and is_greyed_floor(id)
		if greyed:
			label = "%s  (blocked)" % id
		var i := _mod_list.add_item(label)
		_mod_list.set_item_metadata(i, id)
		if greyed:
			_mod_list.set_item_custom_fg_color(i, Color(0.55, 0.55, 0.6))
		if id == current:
			select = i
	if select >= 0:
		_mod_list.select(select)


func _on_module_item_selected(index: int) -> void:
	if _syncing or _mod_sel.is_empty():
		return
	var id := str(_mod_list.get_item_metadata(index))
	if id.is_empty():
		return
	var ov_map := str(_mod_sel.get("ov_map", ""))
	var key := str(_mod_sel.get("key", ""))
	if ov_map.is_empty() or key.is_empty():
		return
	if not bool(_mod_sel.get("assignable", true)):
		return
	_mod_sel["module_id"] = id
	_mod_sel["overridden"] = true
	_mod_current.text = id
	_mod_note.text = module_note(_mod_sel)
	_mod_note.visible = not _mod_note.text.is_empty()
	module_override_set.emit(ov_map, key, id)


func _on_mod_alt() -> void:
	if _mod_sel.is_empty():
		return
	var alt: Variant = _mod_sel.get("alt", {})
	if alt is Dictionary and not (alt as Dictionary).is_empty():
		module_inspect_requested.emit((alt as Dictionary).duplicate(true))


func _emit() -> void:
	if _syncing or _room.is_empty():
		return
	var role := _role.get_item_text(_role.selected)
	var next_room := _room.duplicate(true)
	next_room["stable_id"] = _stable.text.strip_edges()
	next_room["role"] = role
	var mapped := _LATTICE.compartment_for_role(role)
	var vented := _vented.button_pressed
	if mapped.is_empty():
		vented = false
		_vented.set_pressed_no_signal(false)
	var next_vars := {
		"oxygen_bp": int(_oxygen.value),
		"depressurized": _depress.button_pressed,
		"vented": vented,
		"radiation_bp": int(_rad.value),
		"temperature_c": int(_temp.value),
		"notes": _notes.text,
	}
	_apply_atmosphere_honesty(role, next_vars)
	room_edited.emit(next_room, next_vars)


func _emit_hazard() -> void:
	if _syncing or _hazard.is_empty():
		return
	var next_zone := _hazard.duplicate(true)
	next_zone["module_id"] = _h_module.text.strip_edges()
	next_zone["rationale"] = _h_rationale.text
	_hazard = next_zone
	hazard_edited.emit(next_zone)


func _apply_atmosphere_honesty(role: String, vars: Dictionary) -> void:
	var cid := _LATTICE.compartment_for_role(role)
	_cid_label.text = cid if cid != "" else "—"
	_atm_note.text = _atmosphere_honesty(role)
	if cid.is_empty():
		_vented.disabled = true
		_vented.set_pressed_no_signal(false)
	else:
		_vented.disabled = false
		_vented.set_pressed_no_signal(bool(vars.get("vented", false)))


func _atmosphere_honesty(role: String) -> String:
	var cid := _LATTICE.compartment_for_role(role)
	if cid.is_empty():
		return "preview only — no hull compartment. v1 markers do not ignite, vent, or change suit O2."
	return "On a boarded derelict, suit O2 always drains (field_atmosphere). This slider is hull/compartment state for mapped roles (bridge, engineering, cargo). hydroponics is a loader alias the builder cannot stamp. v1 preview/export only — no live ignite."


func _hazard_honesty(compartment_id: String) -> String:
	if compartment_id.strip_edges().is_empty():
		return "Preview/export marker only — no live ignite. Preview only — no hull compartment."
	return "Preview/export marker only — no live ignite. Layout overlay is link-shaped; runtime ignition is a later follow-up."


func _emit_prop() -> void:
	if _syncing or _prop.is_empty():
		return
	var next_prop := _prop.duplicate(true)
	next_prop["locked"] = _pr_locked.button_pressed
	_prop = next_prop
	prop_edited.emit(next_prop)


func _emit_portal() -> void:
	if _syncing or _portal.is_empty():
		return
	var next_portal := _portal.duplicate(true)
	next_portal["state"] = _p_state.get_item_text(_p_state.selected)
	_portal = next_portal
	if str(next_portal["state"]) == "BREACH":
		_p_note.text = "BREACH compiles with an empty module_id (no doorway mesh)."
	else:
		_p_note.text = "Doorway module follows this state at compile."
	portal_edited.emit(next_portal)


func _format_xyz(cell: Variant) -> String:
	if cell is Array and (cell as Array).size() >= 3:
		var a: Array = cell
		return "[%d, %d, %d]" % [int(a[0]), int(a[1]), int(a[2])]
	if cell is Vector3i:
		var c: Vector3i = cell
		return "[%d, %d, %d]" % [c.x, c.y, c.z]
	return "—"


func _cell_key(cell: Variant) -> String:
	if cell is Array and (cell as Array).size() >= 3:
		var a: Array = cell
		return "%d|%d|%d" % [int(a[2]), int(a[0]), int(a[1])]
	if cell is Vector3i:
		var c: Vector3i = cell
		return "%d|%d|%d" % [c.z, c.x, c.y]
	return "?"


func _format_cells(cells: Variant) -> String:
	var arr: Array = cells if cells is Array else []
	var parts: PackedStringArray = PackedStringArray()
	for c in arr:
		if c is Vector2i:
			parts.append("(%d,%d)" % [c.x, c.y])
		elif c is Array and c.size() >= 2:
			parts.append("(%d,%d)" % [int(c[0]), int(c[1])])
	return "%d: %s" % [parts.size(), ", ".join(parts)]


func _ro_line(caption: String) -> Label:
	return _ro_line_in(_fields, caption)


func _ro_line_in(host: VBoxContainer, caption: String) -> Label:
	var value := Label.new()
	value.text = "—"
	_labeled_in(host, caption, value)
	return value


func _edit_line(caption: String) -> LineEdit:
	var edit := LineEdit.new()
	_labeled(caption, edit)
	return edit


func _spin(caption: String, lo: float, hi: float, value: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.rounded = true
	s.value = value
	s.value_changed.connect(func(_v: float) -> void: _emit())
	_labeled(caption, s)
	return s


func _check(caption: String) -> CheckBox:
	var c := CheckBox.new()
	c.text = caption
	c.toggled.connect(func(_v: bool) -> void: _emit())
	_fields.add_child(c)
	return c


func _labeled(caption: String, widget: Control) -> void:
	_labeled_in(_fields, caption, widget)


func _labeled_in(host: VBoxContainer, caption: String, widget: Control) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = caption
	l.custom_minimum_size.x = 110
	row.add_child(l)
	widget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(widget)
	host.add_child(row)
