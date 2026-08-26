class_name StructuralPreview
extends Node3D
## 3D StructuralPlan preview. Loads ship_structural_v0 module GLBs via
## GLTFDocument from the content root. Missing files fall back to CSG.
## Never instances wrapper .tscn scenes or reads processed_asset_source.

## v1 preview kit only. Do not interpolate {kit_id}; ithappy lives under ithappy/.
const KIT_ID := "ship_structural_v0"
const CELL_SIZE_M := 4.0
const DECK_HEIGHT_M := 4.0

const FAMILY_COLORS := {
	"floor": Color(0.52, 0.56, 0.60),
	"ceiling": Color(0.40, 0.44, 0.50),
	"wall": Color(0.64, 0.66, 0.70),
	"portal": Color(0.28, 0.78, 0.88),
}

var glb_count := 0
var fallback_count := 0
var floor_glb_count := 0
var wall_glb_count := 0
var doorway_glb_count := 0
var floor_placement_count := 0
var missing_ids: PackedStringArray = PackedStringArray()
## True only when every placed piece loaded from a GLB (no CSG fallback).
var claimed_kit_preview := false

var _content_root := ""
var _offline := true
var _active_deck := 0
var _pieces: Node3D
var _prop_root: Node3D
var _gltf_cache: Dictionary = {} # module_id or path -> Node prototype (not in tree)
var _missing: Dictionary = {} # module_id or path -> true
var _palettes: Dictionary = {}
var _highlight_layer := ""
var _highlight_key := ""
var _highlight_mat: StandardMaterial3D
var prop_glb_count := 0
var prop_fallback_count := 0


func _ready() -> void:
	_ensure_pieces()


func _exit_tree() -> void:
	_clear_pieces()
	_clear_props()
	_clear_cache()


func _ensure_pieces() -> void:
	if _pieces != null:
		return
	_pieces = Node3D.new()
	_pieces.name = "Pieces"
	add_child(_pieces)


func _ensure_props() -> void:
	if _prop_root != null:
		return
	_prop_root = Node3D.new()
	_prop_root.name = "Props"
	add_child(_prop_root)


func configure(content_root: String, offline: bool) -> void:
	var root := content_root.strip_edges().simplify_path()
	if root == _content_root and offline == _offline:
		return
	_content_root = root
	_offline = offline or root.is_empty()
	_clear_cache()


func set_active_deck(deck: int) -> void:
	if deck == _active_deck:
		return
	_active_deck = deck
	_apply_deck_fade()


func apply_plan(plan: Dictionary) -> void:
	_ensure_pieces()
	_clear_pieces()
	glb_count = 0
	fallback_count = 0
	floor_glb_count = 0
	wall_glb_count = 0
	doorway_glb_count = 0
	floor_placement_count = 0
	missing_ids = PackedStringArray()
	claimed_kit_preview = false
	if plan.is_empty():
		return
	var floors: Variant = plan.get("floor_placements", [])
	if floors is Array:
		floor_placement_count = (floors as Array).size()
	_spawn_layer(floors, "floor", true)
	_spawn_layer(plan.get("ceiling_placements", []), "ceiling", true)
	_spawn_layer(plan.get("placements", []), "edge", false)
	claimed_kit_preview = glb_count > 0 and fallback_count == 0 and not _offline
	_apply_deck_fade()


func status_text() -> String:
	if _offline:
		return "preview: CSG (offline)"
	if claimed_kit_preview:
		return "preview: %s (%d GLBs)" % [KIT_ID, glb_count]
	if glb_count == 0 and fallback_count == 0:
		return "preview: empty"
	var miss := ", ".join(missing_ids)
	if miss.is_empty():
		return "preview: CSG fallback (%d GLB, %d CSG) — not claiming kit preview" % [
			glb_count, fallback_count
		]
	return "preview: CSG fallback missing %s — not claiming kit preview" % miss


func has_kit_floor_glbs() -> bool:
	return floor_glb_count > 0


## Hide occupancy CSG floors only when every occupied cell has a floor GLB.
func covers_occupied_floors() -> bool:
	return floor_placement_count > 0 and floor_glb_count == floor_placement_count


func piece_nodes() -> Array:
	if _pieces == null:
		return []
	return _pieces.get_children()


func prop_nodes() -> Array:
	if _prop_root == null:
		return []
	return _prop_root.get_children()


func apply_props(props: Array, palettes: Dictionary = {}) -> void:
	_ensure_props()
	_clear_props()
	_palettes = palettes
	prop_glb_count = 0
	prop_fallback_count = 0
	if props.is_empty():
		return
	for rec_v in props:
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		if str(rec.get("kind", "")) == "Door":
			continue
		var node := _make_prop(rec)
		if node == null:
			continue
		var cell := _prop_cell(rec)
		node.position = Vector3(
			float(cell.x) * CELL_SIZE_M,
			float(cell.z) * DECK_HEIGHT_M,
			float(cell.y) * CELL_SIZE_M
		)
		node.rotation_degrees = Vector3(0.0, float(int(rec.get("rotation", 0))) * 90.0, 0.0)
		node.set_meta("deck", cell.z)
		node.set_meta("layer", "prop")
		node.set_meta("proto", str(rec.get("proto", "")))
		node.set_meta("visual_id", str(rec.get("visual_id", "")))
		node.set_meta("cell_key", "%d|%d|%d" % [cell.z, cell.x, cell.y])
		_prop_root.add_child(node)
	_apply_deck_fade()


func highlight_selection(layer: String, key: String) -> void:
	_highlight_layer = layer
	_highlight_key = key
	_apply_highlight()


func _apply_highlight() -> void:
	if _pieces == null:
		return
	for child in _pieces.get_children():
		_set_highlight(child, _piece_is_selected(child))


func _piece_is_selected(child: Node) -> bool:
	if _highlight_key.is_empty():
		return false
	if _highlight_layer == "edge":
		return str(child.get_meta("edge_key", "")) == _highlight_key
	return str(child.get_meta("layer", "")) == _highlight_layer and str(child.get_meta("cell_key", "")) == _highlight_key


func _highlight_material() -> StandardMaterial3D:
	if _highlight_mat == null:
		_highlight_mat = StandardMaterial3D.new()
		_highlight_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_highlight_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_highlight_mat.albedo_color = Color(1.0, 0.88, 0.35, 0.32)
		_highlight_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _highlight_mat


func _set_highlight(n: Node, selected: bool) -> void:
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		gi.material_overlay = _highlight_material() if selected else null
	for c in n.get_children():
		_set_highlight(c, selected)


func _spawn_layer(items: Variant, layer: String, always: bool) -> void:
	if not (items is Array):
		return
	for rec_v in items:
		if not (rec_v is Dictionary):
			continue
		var rec: Dictionary = rec_v
		var module_id := str(rec.get("module_id", "")).strip_edges()
		if module_id.is_empty():
			continue
		if not always:
			var required := bool(rec.get("wrapper_required", rec.get("placement_required", false)))
			if not required:
				continue
		var node := _make_piece(module_id, layer)
		if node == null:
			continue
		node.position = _vec3(rec.get("position", []))
		node.rotation_degrees = Vector3(0.0, float(rec.get("yaw_degrees", 0.0)), 0.0)
		node.set_meta("deck", _deck_of(rec))
		node.set_meta("layer", layer)
		node.set_meta("module_id", module_id)
		node.set_meta("cell_key", str(rec.get("cell_key", "")))
		node.set_meta("edge_key", str(rec.get("edge_key", rec.get("key", ""))))
		node.set_meta("kind", str(rec.get("kind", rec.get("state", ""))))
		node.set_meta("state", str(rec.get("state", rec.get("kind", ""))))
		node.set_meta("portal", bool(rec.get("portal", false)))
		_pieces.add_child(node)


func _make_piece(module_id: String, layer: String) -> Node3D:
	var visual := _try_glb(module_id)
	var from_glb := visual != null
	if visual == null:
		fallback_count += 1
		if missing_ids.find(module_id) < 0:
			missing_ids.append(module_id)
		# Occupancy CSG already draws floors; skip a second CSG floor layer.
		if layer == "floor":
			return null
		visual = _make_csg(_family(module_id, layer))
	else:
		glb_count += 1
		match layer:
			"floor":
				floor_glb_count += 1
			"edge":
				if _family(module_id, layer) == "portal":
					doorway_glb_count += 1
				else:
					wall_glb_count += 1
	var wrap := Node3D.new()
	wrap.name = "%s_%s" % [layer, module_id]
	wrap.add_child(visual)
	wrap.set_meta("from_glb", from_glb)
	return wrap


func _try_glb(module_id: String) -> Node3D:
	if _offline or _content_root.is_empty() or module_id.is_empty():
		return null
	if module_id.ends_with(".tscn") or module_id.contains("\\") or module_id.contains("/"):
		return null
	if _missing.has(module_id):
		return null
	if _gltf_cache.has(module_id):
		var proto: Node = _gltf_cache[module_id]
		var copy := proto.duplicate()
		return copy as Node3D
	var path := _glb_path(module_id)
	if path.ends_with(".tscn") or not FileAccess.file_exists(path):
		_missing[module_id] = true
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state, 0, path.get_base_dir())
	if err != OK:
		_missing[module_id] = true
		return null
	var scene := doc.generate_scene(state)
	if scene == null:
		_missing[module_id] = true
		return null
	var root := scene as Node3D
	if root == null:
		root = Node3D.new()
		root.add_child(scene)
	_gltf_cache[module_id] = root
	var inst := root.duplicate() as Node3D
	return inst


func _glb_path(module_id: String) -> String:
	# HARD-CODED ship_structural_v0. ithappy is not a v1 preview kit.
	var kit_dir := _content_root.path_join("assets").path_join("imported").path_join("structural").path_join(KIT_ID)
	return kit_dir.path_join(module_id).path_join("%s.glb" % module_id)


func _make_csg(family: String) -> Node3D:
	var root := Node3D.new()
	var box := CSGBox3D.new()
	box.use_collision = false
	match family:
		"floor":
			box.size = Vector3(CELL_SIZE_M, 0.12, CELL_SIZE_M)
			box.position = Vector3(0.0, 0.06, 0.0)
		"ceiling":
			box.size = Vector3(CELL_SIZE_M, 0.12, CELL_SIZE_M)
			box.position = Vector3(0.0, DECK_HEIGHT_M - 0.06, 0.0)
		"portal":
			box.size = Vector3(CELL_SIZE_M - 0.4, 3.2, 0.22)
			box.position = Vector3(0.0, 1.6, 0.0)
		_:
			box.size = Vector3(CELL_SIZE_M, 3.0, 0.18)
			box.position = Vector3(0.0, 1.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = FAMILY_COLORS.get(family, Color(0.6, 0.6, 0.62))
	box.material = mat
	root.add_child(box)
	return root


func _family(module_id: String, layer: String) -> String:
	if layer == "floor":
		return "floor"
	if layer == "ceiling" or module_id.contains("ceiling"):
		return "ceiling"
	if module_id.contains("doorway") or module_id.contains("portal") or module_id.contains("bulkhead"):
		return "portal"
	if module_id.contains("floor") or module_id.contains("ramp"):
		return "floor"
	return "wall"


func _deck_of(rec: Dictionary) -> int:
	if rec.has("deck"):
		return int(rec["deck"])
	var cell: Variant = rec.get("cell", [])
	if cell is Array and (cell as Array).size() >= 3:
		return int(cell[2])
	var key := str(rec.get("cell_key", rec.get("edge_key", rec.get("key", ""))))
	var parts := key.split("|")
	if parts.size() >= 1 and parts[0].is_valid_int():
		return int(parts[0])
	return 0


func _vec3(v: Variant) -> Vector3:
	if v is Vector3:
		return v
	if v is Array and (v as Array).size() >= 3:
		var a: Array = v
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


func _make_prop(rec: Dictionary) -> Node3D:
	var proto := str(rec.get("proto", ""))
	var visual_id := str(rec.get("visual_id", ""))
	if visual_id.is_empty():
		visual_id = _proto_visual_id(proto)
	var stand_in := proto == "bunk" or bool(rec.get("stand_in", false))
	var path := _binding_scene_path(visual_id)
	if path.is_empty():
		path = str(rec.get("visual_scene_path", ""))
	var visual := _try_prop_glb(path)
	var from_glb := visual != null
	if visual == null:
		prop_fallback_count += 1
		visual = _make_prop_csg(rec, proto, stand_in)
	else:
		prop_glb_count += 1
		if stand_in:
			_attach_label(visual, "preview stand-in")
	var wrap := Node3D.new()
	wrap.name = "prop_%s" % proto
	wrap.add_child(visual)
	wrap.set_meta("from_glb", from_glb)
	wrap.set_meta("stand_in", stand_in)
	return wrap


func _proto_visual_id(proto: String) -> String:
	var map: Variant = _palettes.get("proto_visual", {})
	if map is Dictionary and (map as Dictionary).has(proto):
		return str((map as Dictionary)[proto])
	return ""


func _binding_scene_path(visual_id: String) -> String:
	if visual_id.is_empty():
		return ""
	for bucket in ["components", "dressing", "objectives"]:
		for rec_v in _palettes.get(bucket, []):
			if not (rec_v is Dictionary):
				continue
			var rec: Dictionary = rec_v
			if str(rec.get("id", rec.get("asset_id", ""))) == visual_id:
				var path := str(rec.get("visual_scene_path", ""))
				if path.ends_with(".tscn"):
					return ""
				return path
	return ""


func _try_prop_glb(visual_scene_path: String) -> Node3D:
	if _offline or _content_root.is_empty():
		return null
	var rel := visual_scene_path.strip_edges()
	if rel.is_empty() or rel.ends_with(".tscn"):
		return null
	if rel.begins_with("res://"):
		rel = rel.substr(6)
	if rel.contains(".."):
		return null
	var path := _content_root.path_join(rel).simplify_path()
	if path.ends_with(".tscn") or not FileAccess.file_exists(path):
		return null
	return _load_glb_file(path)


func _load_glb_file(path: String) -> Node3D:
	if _missing.has(path):
		return null
	if _gltf_cache.has(path):
		var proto: Node = _gltf_cache[path]
		return proto.duplicate() as Node3D
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state, 0, path.get_base_dir())
	if err != OK:
		_missing[path] = true
		return null
	var scene := doc.generate_scene(state)
	if scene == null:
		_missing[path] = true
		return null
	var root := scene as Node3D
	if root == null:
		root = Node3D.new()
		root.add_child(scene)
	_gltf_cache[path] = root
	return root.duplicate() as Node3D


func _make_prop_csg(rec: Dictionary, proto: String, stand_in: bool) -> Node3D:
	var root := Node3D.new()
	var primitive := str(rec.get("primitive", ""))
	if primitive.is_empty():
		primitive = _gameplay_primitive(proto)
	var albedo := _parse_color(str(rec.get("albedo", "")))
	if albedo.a <= 0.0:
		albedo = _gameplay_albedo(proto)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = albedo
	var shape := _csg_primitive(primitive)
	shape.use_collision = false
	shape.material = mat
	root.add_child(shape)
	var caption := "preview stand-in" if stand_in else proto
	if caption.is_empty():
		caption = "prop"
	_attach_label(root, caption)
	return root


func _csg_primitive(primitive: String) -> CSGPrimitive3D:
	match primitive.to_lower():
		"cylinder":
			var cyl := CSGCylinder3D.new()
			cyl.radius = 0.28
			cyl.height = 1.2
			cyl.position = Vector3(0, 0.6, 0)
			return cyl
		"sphere":
			var sph := CSGSphere3D.new()
			sph.radius = 0.4
			sph.position = Vector3(0, 0.4, 0)
			return sph
		"capsule":
			var cap := CSGCylinder3D.new()
			cap.radius = 0.22
			cap.height = 1.0
			cap.position = Vector3(0, 0.5, 0)
			return cap
		_:
			var box := CSGBox3D.new()
			box.size = Vector3(0.8, 1.1, 0.8)
			box.position = Vector3(0, 0.55, 0)
			return box


func _gameplay_primitive(proto: String) -> String:
	for rec_v in _palettes.get("gameplay_props", []):
		if rec_v is Dictionary and str((rec_v as Dictionary).get("id", "")) == proto:
			return str((rec_v as Dictionary).get("primitive", "box"))
	return "box"


func _gameplay_albedo(proto: String) -> Color:
	for rec_v in _palettes.get("gameplay_props", []):
		if rec_v is Dictionary and str((rec_v as Dictionary).get("id", "")) == proto:
			return _parse_color(str((rec_v as Dictionary).get("albedo", "")))
	return Color(0.62, 0.58, 0.48)


func _parse_color(s: String) -> Color:
	var t := s.strip_edges()
	if t.is_empty():
		return Color(0, 0, 0, 0)
	if t.begins_with("#"):
		return Color.html(t)
	return Color(0, 0, 0, 0)


func _attach_label(host: Node3D, text: String) -> void:
	var lab := Label3D.new()
	lab.text = text
	lab.position = Vector3(0, 1.35, 0)
	lab.pixel_size = 0.012
	lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lab.modulate = Color(1.0, 0.92, 0.55)
	host.add_child(lab)


func _prop_cell(rec: Dictionary) -> Vector3i:
	var cell: Variant = rec.get("cell", [])
	if cell is Vector3i:
		return cell
	if cell is Array and (cell as Array).size() >= 3:
		var a: Array = cell
		return Vector3i(int(a[0]), int(a[1]), int(a[2]))
	return Vector3i.ZERO


func _apply_deck_fade() -> void:
	for host in [_pieces, _prop_root]:
		if host == null:
			continue
		for child in host.get_children():
			var deck := int(child.get_meta("deck", 0))
			var alpha := 1.0
			if deck > _active_deck:
				alpha = 0.18
			elif deck < _active_deck:
				alpha = 0.38
			_set_fade(child, alpha)
	# Overlay highlight is independent of transparency; re-apply so a deck
	# switch cannot leave a stale overlay on rebuilt-or-faded instances.
	_apply_highlight()


func _set_fade(n: Node, alpha: float) -> void:
	if n is GeometryInstance3D:
		var gi := n as GeometryInstance3D
		gi.transparency = clampf(1.0 - alpha, 0.0, 1.0)
	for c in n.get_children():
		_set_fade(c, alpha)


func _clear_pieces() -> void:
	if _pieces == null:
		return
	for c in _pieces.get_children():
		_pieces.remove_child(c)
		c.free()


func _clear_props() -> void:
	if _prop_root == null:
		return
	for c in _prop_root.get_children():
		_prop_root.remove_child(c)
		c.free()


func _clear_cache() -> void:
	for key in _gltf_cache:
		var n: Node = _gltf_cache[key]
		if is_instance_valid(n):
			n.free()
	_gltf_cache.clear()
	_missing.clear()
