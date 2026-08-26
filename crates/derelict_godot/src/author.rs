//! `DerelictAuthor` — compile/validate/palette bridge for the builder.
//! `DerelictGenerator` is unchanged. Playable export is deferred (PR 11).

use crate::coerce::{coerce_golden_value, golden_from_json};
use derelict_core::authoring::{
    compile_authored, proto_visual as proto_visual_lookup, AuthorPalettes, BuilderKitCatalog,
    ComponentPaletteEntry, GameplayPropEntry, GoldenArea, GoldenScope, ItemPaletteEntry,
    StaleClass, StaleOverride, VisualBinding, VisualBindingIndex,
};
use derelict_core::stages::furnish::interior_zones;
use derelict_core::structural::compile::{
    DefaultModulePicker, ModulePicker, CEILING_MODULE, CORRIDOR_FLOOR_MODULE, DOOR_MODULE,
    FLOOR_MODULE, HATCH_MODULE, INNER_CORNER_MODULE, LOCKED_MODULE, OUTER_CORNER_MODULE,
    T_JUNCTION_MODULE, WALL_MODULE,
};
use derelict_core::structural::plan::{
    DamageVariant, EdgeRecord, FloorPlacement, RoomId, StructuralPlan, Topology, NO_ROOM,
};
use derelict_core::structural::sockets::{SocketCatalog, SocketModulePicker};
use derelict_core::structural::validate::{validate, ValidationIssue, ValidationPolicy};
use derelict_core::topology::room_path;
use godot::builtin::{GString, PackedStringArray, VarArray, VarDictionary, Variant, VariantType};
use godot::classes::RefCounted;
use godot::meta::ToGodot;
use godot::obj::Base;
use godot::prelude::{godot_api, GodotClass};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

const PRIMARY_KIT: &str = "ship_structural_v0";
const KIT_FILES: &[&str] = &[
    "data/kits/ship_structural_v0.json",
    "data/kits/ship_structural_industrial.json",
    "data/kits/ship_structural_hazard.json",
];
const GAMEPLAY_PROPS_FILE: &str = "data/kits/gameplay_prop_v0.json";
const SOCKET_DIR: &str = "data/placement/contracts/structural/ship_structural_v0";
const VISUAL_BINDINGS_FILE: &str = "data/props/visual_bindings.generated.json";
const COMPONENTS_FILE: &str = "data/components/component_catalog.json";
const LOOT_TABLES_FILE: &str = "data/items/loot_tables.json";
const RECIPES_FILE: &str = "data/recipes/recipe_definitions.json";
const ITEM_FILES: &[&str] = &[
    "data/items/item_definitions.json",
    "data/items/junk_items.json",
    "data/items/unique_items.json",
    "data/items/utility_item_definitions.json",
    "data/items/medicine_definitions.json",
    "data/items/trade_item_definitions.json",
    "data/materials/material_definitions.json",
];

#[derive(GodotClass)]
#[class(init, base=RefCounted)]
pub struct DerelictAuthor {
    base: Base<RefCounted>,
    #[init(val = None)]
    data: Option<AuthorPalettes>,
    #[init(val = Vec::new())]
    extra_kits: Vec<BuilderKitCatalog>,
}

impl DerelictAuthor {
    fn palettes_ref(&mut self) -> &AuthorPalettes {
        self.ensure_palettes();
        self.data.as_ref().unwrap()
    }

    fn ensure_palettes(&mut self) {
        if self.data.is_none() {
            self.data = Some(AuthorPalettes::offline().unwrap_or_default());
        }
    }

    fn contracts_loaded(&self) -> bool {
        self.data
            .as_ref()
            .is_some_and(|p| !p.sockets.modules.is_empty())
    }

    fn compile_golden(&self, golden: &GoldenArea) -> Result<CompileOut, String> {
        let topology = golden.to_topology()?;
        let palettes = self.data.as_ref();
        let socket_picker;
        let picker: &dyn ModulePicker = if palettes.is_some_and(|p| !p.sockets.modules.is_empty()) {
            socket_picker = SocketModulePicker {
                catalog: palettes.unwrap().sockets.clone(),
            };
            &socket_picker
        } else {
            &DefaultModulePicker
        };
        let (plan, stale) = compile_authored(&topology, picker, &golden.module_overrides);
        let mut issues = Vec::new();
        match author_policy(golden, &topology) {
            Ok(policy) => {
                if let Err(v) = validate(&plan, &topology, &policy) {
                    issues.extend(v);
                }
            }
            Err(e) => issues.push(ValidationIssue {
                code: derelict_core::structural::validate::IssueCode::CriticalPathBroken,
                detail: e,
            }),
        }
        Ok(CompileOut {
            plan,
            topology,
            stale,
            issues,
            golden_ids: golden.room_stable_ids(),
        })
    }
}

struct CompileOut {
    plan: StructuralPlan,
    topology: Topology,
    stale: Vec<StaleOverride>,
    issues: Vec<ValidationIssue>,
    golden_ids: BTreeMap<RoomId, String>,
}

#[godot_api]
impl DerelictAuthor {
    /// Load palettes from a Synaptic Sea content root. Empty path resets offline.
    #[func]
    fn set_content_root(&mut self, path: GString) -> VarDictionary {
        let path = path.to_string();
        let mut errors: Vec<String> = Vec::new();
        let mut kits: Vec<BuilderKitCatalog> = Vec::new();
        let mut palettes = AuthorPalettes::offline().unwrap_or_default();

        if path.trim().is_empty() {
            let item_count = palettes.items.len();
            self.data = Some(palettes);
            self.extra_kits = Vec::new();
            return content_root_result(true, &[], item_count, &errors);
        }

        let root = match resolve_content_root(&path) {
            Ok(p) => p,
            Err(e) => {
                errors.push(e);
                self.data = Some(palettes);
                self.extra_kits = Vec::new();
                return content_root_result(false, &[], self.palettes_ref().items.len(), &errors);
            }
        };

        for rel in KIT_FILES {
            match read_under(&root, rel) {
                Ok(text) => match BuilderKitCatalog::from_json(&text) {
                    Ok(kit) => {
                        if kit.kit_id == PRIMARY_KIT || palettes.kit.modules.is_empty() {
                            palettes.kit = kit.clone();
                        }
                        kits.push(kit);
                    }
                    Err(e) => errors.push(format!("{rel}: {e}")),
                },
                Err(e) => errors.push(e),
            }
        }

        match read_under(&root, GAMEPLAY_PROPS_FILE) {
            Ok(text) => match GameplayPropEntry::load_map(&text) {
                Ok(props) => palettes.gameplay_props = props,
                Err(e) => errors.push(format!("{GAMEPLAY_PROPS_FILE}: {e}")),
            },
            Err(e) => errors.push(e),
        }

        let socket_dir = root.join(SOCKET_DIR);
        match SocketCatalog::load_dir(&socket_dir) {
            Ok(cat) => palettes.sockets = cat,
            Err(e) => errors.push(format!("{SOCKET_DIR}: {e}")),
        }

        match read_under(&root, VISUAL_BINDINGS_FILE) {
            Ok(text) => match VisualBindingIndex::from_json(&text) {
                Ok(v) => palettes.visuals = v,
                Err(e) => errors.push(format!("{VISUAL_BINDINGS_FILE}: {e}")),
            },
            Err(e) => errors.push(e),
        }

        match read_under(&root, COMPONENTS_FILE) {
            Ok(text) => match ComponentPaletteEntry::load_map(&text) {
                Ok(c) => palettes.components = c,
                Err(e) => errors.push(format!("{COMPONENTS_FILE}: {e}")),
            },
            Err(e) => errors.push(e),
        }

        for rel in ITEM_FILES {
            match read_under(&root, rel) {
                Ok(text) => match serde_json::from_str::<Value>(&text) {
                    Ok(v) => ingest_items(&mut palettes.items, &v),
                    Err(e) => errors.push(format!("{rel}: {e}")),
                },
                Err(e) => errors.push(e),
            }
        }

        match read_under(&root, LOOT_TABLES_FILE) {
            Ok(text) => match serde_json::from_str::<Value>(&text) {
                Ok(v) => palettes.loot_tables = loot_table_ids(&v),
                Err(e) => errors.push(format!("{LOOT_TABLES_FILE}: {e}")),
            },
            Err(e) => errors.push(e),
        }

        match read_under(&root, RECIPES_FILE) {
            Ok(text) => match serde_json::from_str::<Value>(&text) {
                Ok(v) => palettes.recipes_ingredients = recipe_ingredients(&v),
                Err(e) => errors.push(format!("{RECIPES_FILE}: {e}")),
            },
            Err(e) => errors.push(e),
        }

        let kit_ids: Vec<String> = kits.iter().map(|k| k.kit_id.clone()).collect();
        let item_count = palettes.items.len();
        self.extra_kits = kits;
        self.data = Some(palettes);
        content_root_result(errors.is_empty(), &kit_ids, item_count, &errors)
    }

    /// Grouped palettes for the builder UI.
    #[func]
    fn palettes(&mut self) -> VarDictionary {
        let extra = self.extra_kits.clone();
        let p = self.palettes_ref();
        palettes_to_dict(p, &extra)
    }

    #[func]
    fn compile(&mut self, golden_dict: VarDictionary) -> VarDictionary {
        self.ensure_palettes();
        match golden_from_dict(&golden_dict) {
            Err(e) => {
                godot::global::godot_error!("DerelictAuthor.compile: {e}");
                error_dict(&e)
            }
            Ok(golden) => match self.compile_golden(&golden) {
                Err(e) => {
                    godot::global::godot_error!("DerelictAuthor.compile: {e}");
                    error_dict(&e)
                }
                Ok(out) => compile_to_dict(&out),
            },
        }
    }

    #[func]
    fn validate(&mut self, golden_dict: VarDictionary) -> VarDictionary {
        self.ensure_palettes();
        match golden_from_dict(&golden_dict) {
            Err(e) => {
                godot::global::godot_error!("DerelictAuthor.validate: {e}");
                error_dict(&e)
            }
            Ok(golden) => match self.compile_golden(&golden) {
                Err(e) => {
                    godot::global::godot_error!("DerelictAuthor.validate: {e}");
                    error_dict(&e)
                }
                Ok(out) => {
                    let mut d = VarDictionary::new();
                    d.set("issues", &issues_array(&out.issues));
                    d.set("stale_overrides", &stale_array(&out.stale));
                    d.set("stats", &stats_dict(&out.plan));
                    d
                }
            },
        }
    }

    #[func]
    fn load_golden(&self, text: GString) -> VarDictionary {
        match load_golden_json(&text.to_string()) {
            Ok(value) => json_to_dict(&value),
            Err(e) => {
                godot::global::godot_error!("DerelictAuthor.load_golden: {e}");
                error_dict(&e)
            }
        }
    }

    #[func]
    fn save_golden(&self, golden_dict: VarDictionary) -> GString {
        match golden_from_dict(&golden_dict) {
            Ok(golden) => match serde_json::to_string_pretty(&golden) {
                Ok(s) => GString::from(s.as_str()),
                Err(e) => {
                    godot::global::godot_error!("DerelictAuthor.save_golden: {e}");
                    GString::new()
                }
            },
            Err(e) => {
                godot::global::godot_error!("DerelictAuthor.save_golden: {e}");
                GString::new()
            }
        }
    }

    #[func]
    fn proto_visual(&mut self, proto: GString) -> GString {
        let key = proto.to_string();
        let mapped = self
            .palettes_ref()
            .proto_visual
            .get(&key)
            .cloned()
            .or_else(|| proto_visual_lookup(&key));
        GString::from(mapped.unwrap_or_default().as_str())
    }

    /// Socket-filtered module ids when a catalog is loaded; otherwise the
    /// `DefaultModulePicker` constant for `kind`/`state`.
    #[func]
    fn legal_modules(&mut self, kind: GString, state: GString) -> PackedStringArray {
        self.ensure_palettes();
        let ids = legal_module_ids(
            self.contracts_loaded()
                .then(|| &self.data.as_ref().unwrap().sockets),
            &kind.to_string(),
            &state.to_string(),
        );
        PackedStringArray::from_iter(ids.into_iter().map(|s| GString::from(s.as_str())))
    }
}

fn golden_from_dict(dict: &VarDictionary) -> Result<GoldenArea, String> {
    let mut value = dict_to_json(dict)?;
    coerce_golden_value(&mut value)?;
    golden_from_json(&value)
}

fn load_golden_json(text: &str) -> Result<Value, String> {
    let mut value: Value =
        serde_json::from_str(text).map_err(|e| format!("failed to parse golden JSON: {e}"))?;
    coerce_golden_value(&mut value)?;
    // Round-trip through the DTO so the Dictionary is canonical.
    let golden = golden_from_json(&value)?;
    serde_json::to_value(&golden).map_err(|e| e.to_string())
}

fn error_dict(msg: &str) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("error", msg);
    d
}

fn content_root_result(
    ok: bool,
    kits: &[String],
    item_count: usize,
    errors: &[String],
) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("ok", ok);
    let mut kit_arr = VarArray::new();
    for k in kits {
        kit_arr.push(&GString::from(k.as_str()).to_variant());
    }
    d.set("kits", &kit_arr);
    d.set("item_count", item_count as i64);
    let mut err_arr = VarArray::new();
    for e in errors {
        err_arr.push(&GString::from(e.as_str()).to_variant());
    }
    d.set("errors", &err_arr);
    d
}

fn resolve_content_root(path: &str) -> Result<PathBuf, String> {
    let p = PathBuf::from(path);
    match p.canonicalize() {
        Ok(c) if c.is_dir() => Ok(c),
        Ok(_) => Err(format!("content root is not a directory: {path}")),
        Err(e) => {
            if p.is_dir() {
                Ok(p)
            } else {
                Err(format!("content root not found ({path}): {e}"))
            }
        }
    }
}

fn read_under(root: &Path, rel: &str) -> Result<String, String> {
    let path = root.join(rel);
    std::fs::read_to_string(&path).map_err(|e| format!("{rel}: {e}"))
}

fn ingest_items(out: &mut BTreeMap<String, ItemPaletteEntry>, value: &Value) {
    let Some(obj) = value.as_object() else {
        return;
    };
    if let Some(items) = obj.get("items").and_then(Value::as_object) {
        ingest_item_object(out, items, "");
        return;
    }
    if let Some(materials) = obj.get("materials").and_then(Value::as_object) {
        ingest_item_object(out, materials, "material");
        return;
    }
    ingest_item_object(out, obj, "");
}

fn ingest_item_object(
    out: &mut BTreeMap<String, ItemPaletteEntry>,
    obj: &Map<String, Value>,
    default_category: &str,
) {
    for (id, entry) in obj {
        if is_meta_key(id) {
            continue;
        }
        let Some(rec) = entry.as_object() else {
            continue;
        };
        let display_name = rec
            .get("display_name")
            .and_then(Value::as_str)
            .unwrap_or(id)
            .to_string();
        let category = rec
            .get("category")
            .and_then(Value::as_str)
            .unwrap_or(default_category)
            .to_string();
        out.insert(
            id.clone(),
            ItemPaletteEntry {
                item_id: id.clone(),
                display_name,
                category,
            },
        );
    }
}

fn is_meta_key(k: &str) -> bool {
    k.starts_with('_')
        || matches!(
            k,
            "version"
                | "schema"
                | "schema_version"
                | "schema_notes"
                | "document_kind"
                | "station_kinds"
                | "quality_tiers"
                | "recipes"
                | "items"
                | "materials"
        )
}

fn loot_table_ids(value: &Value) -> Vec<String> {
    let Some(obj) = value.as_object() else {
        return Vec::new();
    };
    obj.keys()
        .filter(|k| !k.starts_with('_') && *k != "version" && *k != "schema")
        .cloned()
        .collect()
}

fn recipe_ingredients(value: &Value) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let Some(recipes) = value.get("recipes").and_then(Value::as_array) else {
        return out;
    };
    for recipe in recipes {
        if let Some(ing) = recipe.get("ingredients").and_then(Value::as_object) {
            out.extend(ing.keys().cloned());
        }
    }
    out
}

fn palettes_to_dict(p: &AuthorPalettes, extra_kits: &[BuilderKitCatalog]) -> VarDictionary {
    let mut d = VarDictionary::new();
    let mut kits = extra_kits.to_vec();
    if kits.iter().all(|k| k.kit_id != p.kit.kit_id) && !p.kit.kit_id.is_empty() {
        kits.insert(0, p.kit.clone());
    } else if kits.is_empty() && !p.kit.modules.is_empty() {
        kits.push(p.kit.clone());
    }
    let mut kit_arr = VarArray::new();
    for kit in &kits {
        kit_arr.push(&json_to_variant(&json!({
            "kit_id": kit.kit_id,
            "modules": kit.modules.iter().map(|m| json!({
                "module_id": m.module_id,
                "module_family": m.module_family,
                "footprint_cells": m.footprint_cells,
            })).collect::<Vec<_>>(),
        })));
    }
    d.set("kits", &kit_arr);

    let mut furnishing = VarArray::new();
    for (role, rules) in &p.furnishing.rules {
        for rule in rules {
            furnishing.push(&json_to_variant(&json!({
                "role": role.name(),
                "proto": rule.proto,
                "kind": format!("{:?}", rule.kind),
                "place": format!("{:?}", rule.place),
            })));
        }
    }
    d.set("furnishing", &furnishing);
    d.set("components", &visual_bucket(&p.visuals.components));
    d.set("dressing", &visual_bucket(&p.visuals.dressing));
    d.set("objectives", &visual_bucket(&p.visuals.objectives));

    let mut gameplay = VarArray::new();
    for (id, prop) in &p.gameplay_props {
        gameplay.push(&json_to_variant(&json!({
            "id": id,
            "mesh_path": prop.mesh_path,
            "primitive": prop.primitive,
            "albedo": prop.albedo,
        })));
    }
    d.set("gameplay_props", &gameplay);

    let mut items = VarArray::new();
    for (id, item) in &p.items {
        items.push(&json_to_variant(&json!({
            "item_id": id,
            "display_name": item.display_name,
            "category": item.category,
        })));
    }
    d.set("items", &items);

    let mut loot = VarArray::new();
    for id in &p.loot_tables {
        loot.push(&GString::from(id.as_str()).to_variant());
    }
    d.set("loot_tables", &loot);

    let mut ings = VarArray::new();
    for id in &p.recipes_ingredients {
        ings.push(&GString::from(id.as_str()).to_variant());
    }
    d.set("recipes_ingredients", &ings);

    let mut slot_components = VarArray::new();
    for (id, c) in &p.components {
        slot_components.push(&json_to_variant(&json!({
            "id": id,
            "slot": c.slot,
        })));
    }
    d.set("slot_components", &slot_components);
    d.set("proto_visual", &json_to_dict(&json!(p.proto_visual)));
    d
}

fn visual_bucket(map: &BTreeMap<String, VisualBinding>) -> VarArray {
    let mut arr = VarArray::new();
    for (id, b) in map {
        arr.push(&json_to_variant(&json!({
            "id": id,
            "asset_id": b.asset_id,
            "visual_scene_path": b.visual_scene_path,
            "allowed_yaw_deg": b.allowed_yaw_deg,
            "surface": b.surface,
        })));
    }
    arr
}

fn compile_to_dict(out: &CompileOut) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set(
        "plan",
        &json_to_dict(&plan_to_json(&out.plan, |id| name_of(id, &out.golden_ids))),
    );
    d.set("zones", &json_to_dict(&zones_to_json(out)));
    d.set("issues", &issues_array(&out.issues));
    d.set("stale_overrides", &stale_array(&out.stale));
    d.set("stats", &stats_dict(&out.plan));
    d
}

fn name_of(id: RoomId, ids: &BTreeMap<RoomId, String>) -> String {
    if id == NO_ROOM {
        String::new()
    } else {
        ids.get(&id).cloned().unwrap_or_default()
    }
}

fn variant_name(v: DamageVariant) -> &'static str {
    match v {
        DamageVariant::Intact => "intact",
        DamageVariant::Damaged => "damaged",
        DamageVariant::Breached => "breached",
    }
}

fn cell2(x: i32, y: i32) -> Value {
    json!([x, y])
}

fn cell3(x: i32, y: i32, deck: u8) -> Value {
    json!([x, y, deck])
}

fn pos(p: [f32; 3]) -> Value {
    json!([p[0], p[1], p[2]])
}

fn plan_to_json(plan: &StructuralPlan, name_of: impl Fn(RoomId) -> String) -> Value {
    let edge_json = |e: &EdgeRecord, with_placement_id: bool| -> Value {
        let mut m = Map::new();
        m.insert("id".into(), json!(format!("edge:{}", e.edge_key)));
        m.insert("key".into(), json!(e.edge_key));
        m.insert("edge_key".into(), json!(e.edge_key));
        m.insert("deck".into(), json!(e.cell.deck));
        m.insert("cell".into(), cell2(e.cell.x, e.cell.y));
        m.insert("direction".into(), json!(e.direction.name()));
        m.insert(
            "opposite_direction".into(),
            json!(e.direction.opposite().name()),
        );
        m.insert(
            "source_cells".into(),
            json!([
                cell3(
                    e.source_cells[0].x,
                    e.source_cells[0].y,
                    e.source_cells[0].deck
                ),
                cell3(
                    e.source_cells[1].x,
                    e.source_cells[1].y,
                    e.source_cells[1].deck
                )
            ]),
        );
        m.insert(
            "room_ids".into(),
            json!([name_of(e.room_ids.0), name_of(e.room_ids.1)]),
        );
        m.insert("owner_room".into(), json!(name_of(e.room_ids.0)));
        m.insert("other_room".into(), json!(name_of(e.room_ids.1)));
        m.insert("kind".into(), json!(e.kind.name()));
        m.insert("state".into(), json!(e.kind.name()));
        m.insert("module_id".into(), json!(e.module_id));
        m.insert("variant".into(), json!(variant_name(e.variant)));
        m.insert("position".into(), pos(e.position));
        m.insert("yaw_degrees".into(), json!(e.yaw_degrees as f32));
        m.insert("portal".into(), json!(e.portal));
        m.insert("exterior".into(), json!(e.exterior));
        m.insert("placement_required".into(), json!(e.wrapper_required));
        m.insert("wrapper_required".into(), json!(e.wrapper_required));
        if with_placement_id {
            m.insert("placement_id".into(), json!(format!("edge:{}", e.edge_key)));
        }
        m.insert("socket_bindings".into(), json!([]));
        Value::Object(m)
    };

    let occupancy: Map<String, Value> = plan
        .occupancy
        .iter()
        .map(|(k, rec)| {
            (
                k.clone(),
                json!({
                    "cell_key": k,
                    "deck": rec.cell.deck,
                    "cell": cell2(rec.cell.x, rec.cell.y),
                    "room_id": name_of(rec.room_id),
                    "room_ids": [name_of(rec.room_id)],
                    "position": pos(rec.cell.world_pos()),
                    "module_id": rec.module_id,
                    "variant": variant_name(rec.variant),
                    "decal": rec.decal,
                }),
            )
        })
        .collect();
    let edges: Map<String, Value> = plan
        .edges
        .iter()
        .map(|(k, e)| (k.clone(), edge_json(e, false)))
        .collect();
    let placements: Vec<Value> = plan.placements.iter().map(|e| edge_json(e, true)).collect();
    let flat_placement = |f: &FloorPlacement| {
        json!({
            "id": f.id,
            "placement_id": f.id,
            "module_id": f.module_id,
            "position": pos(f.position),
            "yaw_degrees": f.yaw_degrees as f32,
            "deck": f.cell.deck,
            "cell": cell2(f.cell.x, f.cell.y),
            "cell_key": f.cell_key,
            "room_id": name_of(f.room_id),
            "room_ids": [name_of(f.room_id)],
            "variant": variant_name(f.variant),
            "socket_bindings": [],
        })
    };

    json!({
        "occupancy": occupancy,
        "edges": edges,
        "placements": placements,
        "floor_placements": plan.floor_placements.iter().map(flat_placement).collect::<Vec<_>>(),
        "ceiling_placements": plan.ceiling_placements.iter().map(flat_placement).collect::<Vec<_>>(),
        "socket_bindings": plan.socket_bindings.iter().map(|b| json!({
            "placement_id": b.placement_id,
            "socket_id": b.socket_id,
            "neighbor_placement_id": b.neighbor_placement_id,
            "neighbor_socket_id": b.neighbor_socket_id,
            "kind": b.kind,
        })).collect::<Vec<_>>(),
        "errors": plan.errors,
    })
}

fn zones_to_json(out: &CompileOut) -> Value {
    let zones = interior_zones(&out.topology, &out.plan);
    let mut map = Map::new();
    for (id, z) in zones {
        let key = name_of(id, &out.golden_ids);
        if key.is_empty() {
            continue;
        }
        let cells = |v: &[derelict_core::structural::plan::Cell]| {
            v.iter()
                .map(|c| cell3(c.x, c.y, c.deck))
                .collect::<Vec<_>>()
        };
        map.insert(
            key,
            json!({
                "reserved_cells": cells(&z.reserved_cells),
                "wall_slots": cells(&z.wall_slots),
                "center_slots": cells(&z.center_slots),
            }),
        );
    }
    Value::Object(map)
}

fn issues_array(issues: &[ValidationIssue]) -> VarArray {
    let mut arr = VarArray::new();
    for issue in issues {
        arr.push(&json_to_variant(&json!({
            "code": format!("{:?}", issue.code),
            "detail": issue.detail,
        })));
    }
    arr
}

fn stale_array(stale: &[StaleOverride]) -> VarArray {
    let mut arr = VarArray::new();
    for s in stale {
        let class = match s.class {
            StaleClass::Floor => "floor",
            StaleClass::Ceiling => "ceiling",
            StaleClass::Edge => "edge",
        };
        arr.push(&json_to_variant(&json!({
            "class": class,
            "key": s.key,
            "module_id": s.module_id,
        })));
    }
    arr
}

fn stats_dict(plan: &StructuralPlan) -> VarDictionary {
    json_to_dict(&json!({
        "occupied_cells": plan.occupancy.len(),
        "floor_placements": plan.floor_placements.len(),
        "ceiling_placements": plan.ceiling_placements.len(),
        "edges": plan.edges.len(),
        "edge_placements": plan.placements.len(),
        "socket_bindings": plan.socket_bindings.len(),
    }))
}

fn author_policy(golden: &GoldenArea, topology: &Topology) -> Result<ValidationPolicy, String> {
    match golden.scope {
        GoldenScope::Room | GoldenScope::Area => Ok(ValidationPolicy::pre_damage(Vec::new())),
        GoldenScope::Derelict => {
            derelict_critical_path(golden, topology).map(ValidationPolicy::pre_damage)
        }
    }
}

fn derelict_critical_path(golden: &GoldenArea, topology: &Topology) -> Result<Vec<RoomId>, String> {
    if golden.entry_room.is_empty() || golden.goal_room.is_empty() {
        return Err("scope derelict requires both entry_room and goal_room".into());
    }
    let entry = resolve_stable_id(golden, &golden.entry_room)?;
    let goal = resolve_stable_id(golden, &golden.goal_room)?;
    let mut links = Vec::new();
    for p in &topology.portals {
        if p.from_room != NO_ROOM && p.to_room != NO_ROOM {
            links.push((p.from_room, p.to_room));
        }
    }
    for v in &topology.verticals {
        if v.from_room != NO_ROOM && v.to_room != NO_ROOM {
            links.push((v.from_room, v.to_room));
        }
    }
    room_path(entry, goal, &links).ok_or_else(|| {
        format!(
            "no BFS path from '{}' to '{}'",
            golden.entry_room, golden.goal_room
        )
    })
}

fn resolve_stable_id(golden: &GoldenArea, stable_id: &str) -> Result<RoomId, String> {
    golden
        .topology
        .rooms
        .iter()
        .find(|r| r.stable_id == stable_id)
        .map(|r| r.id)
        .ok_or_else(|| format!("unknown room stable_id '{stable_id}'"))
}

fn legal_module_ids(catalog: Option<&SocketCatalog>, kind: &str, state: &str) -> Vec<String> {
    let kind = kind.trim().to_ascii_lowercase();
    let state = state.trim();
    let state_l = state.to_ascii_lowercase();
    let (required, preferred): (&[&str], &str) = match kind.as_str() {
        "floor" => {
            let connective = matches!(
                state_l.as_str(),
                "connective" | "corridor" | "main_spine" | "hub" | "airlock" | "dock"
            );
            (
                &["floor_edge", "floor_top"],
                if connective {
                    CORRIDOR_FLOOR_MODULE
                } else {
                    FLOOR_MODULE
                },
            )
        }
        "ceiling" => (&["ceiling_edge", "ceiling_bottom"], CEILING_MODULE),
        "wall" | "solid" => (&["wall_base", "wall_end"], WALL_MODULE),
        "portal" | "door" => {
            let preferred = match state.to_ascii_uppercase().as_str() {
                "LOCKED" => LOCKED_MODULE,
                "HATCH" => HATCH_MODULE,
                "BREACH" => return Vec::new(),
                _ => DOOR_MODULE,
            };
            (&["portal_edge", "wall_base"], preferred)
        }
        "vertex" => match state_l.as_str() {
            "inner" | "inner_corner" => (&["inner_corner_vertex"] as &[&str], INNER_CORNER_MODULE),
            "outer" | "outer_corner" => (&["outer_corner_vertex"], OUTER_CORNER_MODULE),
            "t" | "t_junction" | "tjunction" => (&["wall_face"], T_JUNCTION_MODULE),
            _ => return vec![INNER_CORNER_MODULE.to_string()],
        },
        _ => return Vec::new(),
    };

    let Some(catalog) = catalog else {
        return if preferred.is_empty() {
            Vec::new()
        } else {
            vec![preferred.to_string()]
        };
    };

    let mut ids: Vec<String> = catalog
        .modules
        .keys()
        .filter(|id| catalog.has_all_kinds(id, required))
        .cloned()
        .collect();
    let is_t_vertex = matches!(state_l.as_str(), "t" | "t_junction" | "tjunction");
    if kind == "vertex"
        && is_t_vertex
        && catalog.modules.contains_key(T_JUNCTION_MODULE)
        && !ids.iter().any(|id| id == T_JUNCTION_MODULE)
    {
        ids.push(T_JUNCTION_MODULE.to_string());
    }
    if ids.is_empty() {
        if !preferred.is_empty() {
            ids.push(preferred.to_string());
        }
        return ids;
    }
    ids.sort();
    if let Some(i) = ids.iter().position(|id| id == preferred) {
        let pref = ids.remove(i);
        ids.insert(0, pref);
    }
    ids
}

fn dict_to_json(dict: &VarDictionary) -> Result<Value, String> {
    let mut map = Map::new();
    for (key, value) in dict.iter_shared() {
        map.insert(variant_key(&key), variant_to_json(&value)?);
    }
    Ok(Value::Object(map))
}

fn variant_key(key: &Variant) -> String {
    if let Ok(s) = key.try_to::<GString>() {
        return s.to_string();
    }
    if let Ok(i) = key.try_to::<i64>() {
        return i.to_string();
    }
    if let Ok(f) = key.try_to::<f64>() {
        if f.is_finite() && f.fract() == 0.0 {
            return (f as i64).to_string();
        }
        return f.to_string();
    }
    key.to_string()
}

fn variant_to_json(v: &Variant) -> Result<Value, String> {
    match v.get_type() {
        VariantType::NIL => Ok(Value::Null),
        VariantType::BOOL => Ok(Value::Bool(v.try_to::<bool>().unwrap_or(false))),
        VariantType::INT => Ok(json!(v.try_to::<i64>().unwrap_or(0))),
        VariantType::FLOAT => {
            let f = v.try_to::<f64>().unwrap_or(0.0);
            Ok(serde_json::Number::from_f64(f)
                .map(Value::Number)
                .unwrap_or(Value::Null))
        }
        VariantType::STRING => Ok(Value::String(
            v.try_to::<GString>()
                .map(|s| s.to_string())
                .unwrap_or_default(),
        )),
        VariantType::ARRAY => {
            let arr: VarArray = v.try_to().map_err(|e| e.to_string())?;
            let mut out = Vec::new();
            for x in arr.iter_shared() {
                out.push(variant_to_json(&x)?);
            }
            Ok(Value::Array(out))
        }
        VariantType::DICTIONARY => {
            let d: VarDictionary = v.try_to().map_err(|e| e.to_string())?;
            dict_to_json(&d)
        }
        other => Err(format!("unsupported variant type {other:?}")),
    }
}

fn json_to_dict(value: &Value) -> VarDictionary {
    let mut d = VarDictionary::new();
    let Some(obj) = value.as_object() else {
        return d;
    };
    for (k, v) in obj {
        d.set(k.as_str(), &json_to_variant(v));
    }
    d
}

fn json_to_variant(value: &Value) -> Variant {
    match value {
        Value::Null => Variant::nil(),
        Value::Bool(b) => b.to_variant(),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.to_variant()
            } else if let Some(u) = n.as_u64() {
                if u <= i64::MAX as u64 {
                    (u as i64).to_variant()
                } else {
                    n.as_f64().unwrap_or(0.0).to_variant()
                }
            } else {
                n.as_f64().unwrap_or(0.0).to_variant()
            }
        }
        Value::String(s) => GString::from(s.as_str()).to_variant(),
        Value::Array(a) => {
            let mut arr = VarArray::new();
            for x in a {
                arr.push(&json_to_variant(x));
            }
            arr.to_variant()
        }
        Value::Object(_) => json_to_dict(value).to_variant(),
    }
}
