class_name PaletteDock
extends VBoxContainer
## Phase 2 prop palette. Groups furnishing protos (role-filtered), visual
## binding buckets, and gameplay CSG primitives. Does not invent Door entries.

signal prop_armed(entry: Dictionary)

const PROTO_MAP_PATH := "res://data/proto_visual_map.json"
const DIRS_NESW: PackedStringArray = ["north", "east", "south", "west"]
const DIR_ROTATION := {
	"south": 0,
	"west": 1,
	"north": 2,
	"east": 3,
}
const KIND_DOOR := "Door"

var _palettes: Dictionary = {}
var _proto_visual: Dictionary = {}
var _slot_by_id: Dictionary = {}
var _role_filter := ""
var _armed: Dictionary = {}
var _lists: Dictionary = {} # group -> ItemList
var _headers: Dictionary = {} # group -> Label
var _empty: Label


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	var title := Label.new()
	title.text = "Prop palette"
	title.theme_type_variation = "HeaderSmall"
	add_child(title)
	_empty = Label.new()
	_empty.text = "Compile occupancy first, then pick a proto. Doors/ladders come from portals and verticals."
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_empty)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 8)
	scroll.add_child(col)
	for spec in [
		["furnishing", "Furnishing"],
		["components", "Visual — components"],
		["dressing", "Visual — dressing"],
		["objectives", "Visual — objectives"],
		["gameplay", "Gameplay props"],
	]:
		var head := Label.new()
		head.text = str(spec[1])
		head.theme_type_variation = "HeaderSmall"
		col.add_child(head)
		var list := ItemList.new()
		list.custom_minimum_size = Vector2(0, 72)
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.item_selected.connect(_on_list_selected.bind(str(spec[0])))
		col.add_child(list)
		_headers[str(spec[0])] = head
		_lists[str(spec[0])] = list
	_load_embedded_proto_map()
	rebuild()


func bind_palettes(palettes: Dictionary) -> void:
	_palettes = palettes.duplicate(true) if not palettes.is_empty() else {}
	_proto_visual = _as_dict(_palettes.get("proto_visual", {}))
	if _proto_visual.is_empty():
		_load_embedded_proto_map()
	_slot_by_id.clear()
	for rec_v in _palettes.get("slot_components", []):
		if rec_v is Dictionary:
			var rec: Dictionary = rec_v
			_slot_by_id[str(rec.get("id", ""))] = str(rec.get("slot", ""))
	rebuild()


func set_role_filter(role: String) -> void:
	if _role_filter == role:
		return
	_role_filter = role
	rebuild()


func get_role_filter() -> String:
	return _role_filter


func get_armed() -> Dictionary:
	return _armed.duplicate(true)


func clear_armed() -> void:
	_armed = {}
	_highlight()
	prop_armed.emit({})


func arm_entry(entry: Dictionary) -> void:
	if entry.is_empty() or str(entry.get("kind", "")) == KIND_DOOR:
		clear_armed()
		return
	_armed = entry.duplicate(true)
	_highlight()
	prop_armed.emit(_armed.duplicate(true))


func entries_for_group(group: String) -> Array:
	match group:
		"furnishing":
			return _furnishing_entries()
		"components":
			return _visual_entries("components")
		"dressing":
			return _visual_entries("dressing")
		"objectives":
			return _visual_entries("objectives")
		"gameplay":
			return _gameplay_entries()
		_:
			return []


static func is_wall_adjacent(entry: Dictionary) -> bool:
	var place := str(entry.get("place", ""))
	if place == "WallAdjacent" or place == "Corner":
		return true
	if str(entry.get("surface", "")).to_lower() == "wall":
		return true
	if str(entry.get("slot", "")).to_lower() == "wall":
		return true
	return bool(entry.get("wall_adjacent", false))


static func is_stand_in(entry: Dictionary) -> bool:
	if bool(entry.get("stand_in", false)):
		return true
	return str(entry.get("proto", "")) == "bunk"


static func rotation_from_facing(facing: String) -> int:
	return int(DIR_ROTATION.get(facing, 0))


static func first_solid_dir(solids: Array) -> String:
	for d in DIRS_NESW:
		if solids.has(d) or solids.has(String(d)):
			return String(d)
	return ""


static func kind_or_skip_door(kind: String, fallback: String = "Furniture") -> String:
	var k := kind.strip_edges()
	if k.is_empty():
		return fallback
	if k == KIND_DOOR or k.to_lower() == "door":
		return ""
	return k


func rebuild() -> void:
	if _empty == null or _lists.is_empty():
		return
	for group in _lists:
		_fill_list(group, entries_for_group(group))
	_empty.visible = _total_count() == 0
	_highlight()


func _total_count() -> int:
	var n := 0
	for group in _lists:
		n += (_lists[group] as ItemList).item_count
	return n


func _fill_list(group: String, entries: Array) -> void:
	if not _lists.has(group) or not _headers.has(group):
		return
	var list: ItemList = _lists[group]
	if list == null:
		return
	list.clear()
	for e_v in entries:
		if not (e_v is Dictionary):
			continue
		var e: Dictionary = e_v
		if str(e.get("kind", "")) == KIND_DOOR:
			continue
		var i := list.add_item(_label_of(e))
		list.set_item_metadata(i, e)
	var head: Label = _headers[group]
	if head == null:
		return
	if group == "furnishing":
		var role := _role_filter if not _role_filter.is_empty() else "all roles"
		head.text = "Furnishing (%s)" % role
	list.visible = list.item_count > 0
	head.visible = list.item_count > 0


func _label_of(entry: Dictionary) -> String:
	var proto := str(entry.get("proto", entry.get("id", "")))
	var visual := str(entry.get("visual_id", ""))
	var tag := ""
	if is_stand_in(entry):
		tag = "  [preview stand-in]"
	elif not visual.is_empty() and visual != proto:
		tag = "  → %s" % visual
	var place := str(entry.get("place", ""))
	if place.is_empty():
		if is_wall_adjacent(entry):
			place = "wall"
		elif str(entry.get("slot", "")) == "center" or str(entry.get("surface", "")) == "floor":
			place = "center"
	if not place.is_empty():
		return "%s%s  (%s)" % [proto, tag, place]
	return "%s%s" % [proto, tag]


func _on_list_selected(index: int, group: String) -> void:
	var list: ItemList = _lists[group]
	var meta: Variant = list.get_item_metadata(index)
	if not (meta is Dictionary):
		return
	# Re-click of the same palette row keeps the arm; it must not stamp a prop.
	arm_entry(meta)
	_deselect_others(group)


func _deselect_others(keep: String) -> void:
	for group in _lists:
		if group == keep:
			continue
		(_lists[group] as ItemList).deselect_all()


func _highlight() -> void:
	if _lists.is_empty():
		return
	var armed_key := _entry_key(_armed)
	for group in _lists:
		var list: ItemList = _lists[group]
		for i in list.item_count:
			var e: Dictionary = list.get_item_metadata(i)
			if _entry_key(e) == armed_key and not armed_key.is_empty():
				list.select(i)
			list.set_item_custom_bg_color(
				i,
				Color(0.35, 0.32, 0.12, 0.6) if _entry_key(e) == armed_key and not armed_key.is_empty() else Color(0, 0, 0, 0)
			)


func _entry_key(entry: Dictionary) -> String:
	if entry.is_empty():
		return ""
	return "%s|%s|%s" % [
		str(entry.get("group", "")),
		str(entry.get("proto", "")),
		str(entry.get("role", "")),
	]


func _furnishing_entries() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for rec_v in _palettes.get("furnishing", []):
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var role := str(rec.get("role", ""))
		if not _role_filter.is_empty() and role != _role_filter:
			continue
		var proto := str(rec.get("proto", "")).strip_edges()
		if proto.is_empty():
			continue
		var kind := kind_or_skip_door(str(rec.get("kind", "Furniture")))
		if kind.is_empty():
			continue
		var place := str(rec.get("place", "Free"))
		var visual := str(_proto_visual.get(proto, ""))
		var key := "%s|%s|%s" % [role, proto, place]
		if seen.has(key):
			continue
		seen[key] = true
		out.append({
			"group": "furnishing",
			"role": role,
			"id": proto,
			"proto": proto,
			"kind": kind,
			"place": place,
			"visual_id": visual,
			"wall_adjacent": place == "WallAdjacent" or place == "Corner",
			"stand_in": proto == "bunk",
			"visual_scene_path": "",
			"primitive": "",
			"albedo": "",
			"surface": "",
			"slot": "",
		})
	return out


func _visual_entries(bucket: String) -> Array:
	var out: Array = []
	for rec_v in _palettes.get(bucket, []):
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var id := str(rec.get("id", rec.get("asset_id", ""))).strip_edges()
		if id.is_empty():
			continue
		var surface := str(rec.get("surface", ""))
		var slot := str(_slot_by_id.get(id, rec.get("slot", "")))
		var place := "Free"
		if surface.to_lower() == "wall" or slot.to_lower() == "wall":
			place = "WallAdjacent"
		elif slot.to_lower() == "center" or surface.to_lower() == "floor" or surface.to_lower() == "ceiling":
			place = "Center"
		var path := str(rec.get("visual_scene_path", ""))
		if path.ends_with(".tscn"):
			path = ""
		out.append({
			"group": bucket,
			"role": "",
			"id": id,
			"proto": id,
			"kind": "Furniture",
			"place": place,
			"visual_id": id,
			"wall_adjacent": place == "WallAdjacent",
			"stand_in": false,
			"visual_scene_path": path,
			"primitive": "",
			"albedo": "",
			"surface": surface,
			"slot": slot,
		})
	return out


func _gameplay_entries() -> Array:
	var out: Array = []
	for rec_v in _palettes.get("gameplay_props", []):
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var id := str(rec.get("id", "")).strip_edges()
		if id.is_empty():
			continue
		var kind := _gameplay_kind(id)
		if kind.is_empty():
			continue
		out.append({
			"group": "gameplay",
			"role": "",
			"id": id,
			"proto": id,
			"kind": kind,
			"place": "Free",
			"visual_id": "",
			"wall_adjacent": false,
			"stand_in": false,
			"visual_scene_path": "",
			"primitive": str(rec.get("primitive", "box")),
			"albedo": str(rec.get("albedo", "")),
			"surface": "",
			"slot": "",
		})
	return out


func _gameplay_kind(id: String) -> String:
	match id:
		"loot_crate", "tool_case":
			return "Container"
		"corpse_bag":
			return "Body"
		_:
			return "Furniture"


func _load_embedded_proto_map() -> void:
	if not _proto_visual.is_empty():
		return
	if not FileAccess.file_exists(PROTO_MAP_PATH):
		return
	var f := FileAccess.open(PROTO_MAP_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if parsed is Dictionary:
		_proto_visual = parsed


func _as_dict(v: Variant) -> Dictionary:
	return v if v is Dictionary else {}
