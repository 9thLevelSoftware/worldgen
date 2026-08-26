class_name InspectorDock
extends VBoxContainer
## Selected-room inspector. Room vars are authored here even though the
## hazards GUI (PR 10) is not in this shell yet.

signal room_edited(room: Dictionary, vars: Dictionary)

const ROLES: PackedStringArray = [
	"airlock", "dock", "corridor", "main_spine", "hub", "ramp", "elevator",
	"bridge", "engineering", "reactor", "life_support", "maintenance",
	"cargo", "hangar", "storage", "armory", "security", "medical",
	"crew_quarters", "mess_hall", "compartment",
]

var _syncing := false
var _room: Dictionary = {}
var _vars: Dictionary = {}
var _fields: VBoxContainer

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


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "Inspector"
	title.theme_type_variation = "HeaderSmall"
	add_child(title)

	_empty = Label.new()
	_empty.text = "Click an occupied cell to select a room."
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
	for r in ROLES:
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


func bind_room(room: Dictionary, vars: Dictionary) -> void:
	_room = room
	_vars = vars.duplicate(true)
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
	var idx := ROLES.find(role)
	_role.select(idx if idx >= 0 else ROLES.find("compartment"))
	_deck.text = str(int(room.get("deck", 0)))
	_cells.text = _format_cells(room.get("cells", []))
	_oxygen.set_value_no_signal(int(vars.get("oxygen_bp", 8500)))
	_depress.set_pressed_no_signal(bool(vars.get("depressurized", false)))
	_vented.set_pressed_no_signal(bool(vars.get("vented", false)))
	_rad.set_value_no_signal(int(vars.get("radiation_bp", 0)))
	_temp.set_value_no_signal(int(vars.get("temperature_c", 18)))
	_notes.text = str(vars.get("notes", ""))
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
	var value := Label.new()
	value.text = "—"
	_labeled(caption, value)
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
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = caption
	l.custom_minimum_size.x = 110
	row.add_child(l)
	widget.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(widget)
	_fields.add_child(row)
