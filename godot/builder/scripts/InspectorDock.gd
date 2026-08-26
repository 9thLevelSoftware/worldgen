class_name InspectorDock
extends VBoxContainer
## Selected room, portal, or vertical inspector.

const _LATTICE := preload("res://scripts/OccupancyLattice.gd")

signal room_edited(room: Dictionary, vars: Dictionary)
signal portal_edited(portal: Dictionary)
signal portal_removed
signal vertical_removed
signal prop_edited(prop: Dictionary)
signal prop_removed

var _syncing := false
var _room: Dictionary = {}
var _vars: Dictionary = {}
var _portal: Dictionary = {}
var _vertical: Dictionary = {}
var _prop: Dictionary = {}
var _fields: VBoxContainer
var _portal_fields: VBoxContainer
var _vert_fields: VBoxContainer
var _prop_fields: VBoxContainer

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


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "Inspector"
	title.theme_type_variation = "HeaderSmall"
	add_child(title)

	_empty = Label.new()
	_empty.text = "Room list: inspect only. Paint: occupied click stamps+selects (re-click inspects). Portal: click A then a cardinal neighbor. Vertical: stacked occupied cells on N and N±1. Props: snap to compiled wall/center slots after compile OK. Delete removes the selected portal, vertical, or prop."
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

	_oxygen = _spin("oxygen_bp", 0, 65535, 8500)
	_depress = _check("depressurized")
	_vented = _check("vented")
	_rad = _spin("radiation_bp", 0, 65535, 0)
	_temp = _spin("temperature_c", -273, 500, 18)
	_notes = _edit_line("notes")
	_notes.text_submitted.connect(func(_t: String) -> void: _emit())
	_notes.focus_exited.connect(_emit)

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


func bind_room(room: Dictionary, vars: Dictionary) -> void:
	_room = room
	_vars = vars.duplicate(true)
	_portal = {}
	_vertical = {}
	_prop = {}
	_portal_fields.visible = false
	_vert_fields.visible = false
	_prop_fields.visible = false
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
	_vented.set_pressed_no_signal(bool(vars.get("vented", false)))
	_rad.set_value_no_signal(int(vars.get("radiation_bp", 0)))
	_temp.set_value_no_signal(int(vars.get("temperature_c", 18)))
	_notes.text = str(vars.get("notes", ""))
	_syncing = false


func bind_portal(portal: Dictionary) -> void:
	_portal = portal.duplicate(true)
	_room = {}
	_vertical = {}
	_prop = {}
	_fields.visible = false
	_vert_fields.visible = false
	_prop_fields.visible = false
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
	_fields.visible = false
	_portal_fields.visible = false
	_prop_fields.visible = false
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
	_fields.visible = false
	_portal_fields.visible = false
	_vert_fields.visible = false
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


func clear() -> void:
	bind_room({}, {})


func _emit() -> void:
	if _syncing or _room.is_empty():
		return
	var role := _role.get_item_text(_role.selected)
	var next_room := _room.duplicate(true)
	next_room["stable_id"] = _stable.text.strip_edges()
	next_room["role"] = role
	var next_vars := {
		"oxygen_bp": int(_oxygen.value),
		"depressurized": _depress.button_pressed,
		"vented": _vented.button_pressed,
		"radiation_bp": int(_rad.value),
		"temperature_c": int(_temp.value),
		"notes": _notes.text,
	}
	room_edited.emit(next_room, next_vars)


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
