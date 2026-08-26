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
var _gltf_cache: Dictionary = {} # module_id -> Node prototype (not in tree)
var _missing: Dictionary = {} # module_id -> true


func _ready() -> void:
	_ensure_pieces()


func _exit_tree() -> void:
	_clear_pieces()
	_clear_cache()


func _ensure_pieces() -> void:
	if _pieces != null:
		return
	_pieces = Node3D.new()
	_pieces.name = "Pieces"
	add_child(_pieces)


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
	_apply_deck_fade()
	claimed_kit_preview = glb_count > 0 and fallback_count == 0 and not _offline


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


func _apply_deck_fade() -> void:
	if _pieces == null:
		return
	for child in _pieces.get_children():
		var deck := int(child.get_meta("deck", 0))
		var alpha := 1.0
		if deck > _active_deck:
			alpha = 0.18
		elif deck < _active_deck:
			alpha = 0.38
		_set_fade(child, alpha)


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


func _clear_cache() -> void:
	for key in _gltf_cache:
		var n: Node = _gltf_cache[key]
		if is_instance_valid(n):
			n.free()
	_gltf_cache.clear()
	_missing.clear()
