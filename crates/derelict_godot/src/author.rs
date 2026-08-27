//! `DerelictAuthor` — compile/validate/palette/export bridge for the builder.
//! `DerelictGenerator` is unchanged.

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
use derelict_core::structural::export::{layout_from_golden, structural_plan_to_json};
use derelict_core::structural::plan::{RoomId, StructuralPlan, Topology, NO_ROOM};
use derelict_core::structural::sockets::SocketCatalog;
use derelict_core::structural::validate::{
    validate, ValidationIssue, ValidationPolicy, FLOOR_MODULES,
};
use derelict_core::topology::room_path;
use derelict_core::Role;
use godot::builtin::{Array, GString, PackedStringArray, VarArray, VarDictionary, Variant, VariantType};
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
const SOCKET_CONTRACTS_PARENT: &str = "data/placement/contracts/structural";
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
    #[init(val = BTreeMap::new())]
    sockets_by_kit: BTreeMap<String, SocketCatalog>,
}

impl DerelictAuthor {
    fn palettes_ref(&mut self) -> &AuthorPalettes {
        self.ensure_palettes();
        self.data.as_ref().expect("palettes initialized")
    }

    fn ensure_palettes(&mut self) {
        if self.data.is_none() {
            self.data = Some(AuthorPalettes::offline().unwrap_or_default());
        }
    }

    fn catalog_for(&self, kit_id: &str) -> Option<&SocketCatalog> {
        self.sockets_by_kit
            .get(kit_id)
            .filter(|c| !c.modules.is_empty())
            .or_else(|| {
                self.data
                    .as_ref()
                    .map(|p| &p.sockets)
                    .filter(|c| !c.modules.is_empty())
            })
    }

    fn picker_for(&self, kit_id: &str) -> &dyn ModulePicker {
        match self.catalog_for(kit_id) {
            Some(catalog) => catalog,
            None => &DefaultModulePicker,
        }
    }

    fn floor_modules_for(&self, kit_id: &str) -> Option<Vec<String>> {
        let catalog = self.catalog_for(kit_id)?;
        let mut ids: Vec<String> = catalog
            .modules
            .values()
            .filter(|m| {
                m.sockets
                    .iter()
                    .any(|s| s.kind == "floor_edge" || s.kind == "floor_top")
            })
            .map(|m| m.module_id.clone())
            .collect();
        if ids.is_empty() {
            return Some(FLOOR_MODULES.iter().map(|s| (*s).to_string()).collect());
        }
        ids.sort();
        ids.dedup();
        Some(ids)
    }

    fn compile_golden(&self, golden: &GoldenArea) -> Result<CompileOut, String> {
        let topology = golden.to_topology()?;
        let picker = self.picker_for(&golden.kit_id);
        let (plan, stale) = compile_authored(&topology, picker, &golden.module_overrides);
        let mut issues = Vec::new();
        match author_policy(golden, &topology) {
            Ok(mut policy) => {
                if let Some(floors) = self.floor_modules_for(&golden.kit_id) {
                    policy.allowed_floor_modules = Some(floors);
                }
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
            self.sockets_by_kit = BTreeMap::new();
            return content_root_result(true, &[], item_count, &errors);
        }

        let root = match resolve_content_root(&path) {
            Ok(p) => p,
            Err(e) => {
                errors.push(e);
                self.data = Some(palettes);
                self.extra_kits = Vec::new();
                self.sockets_by_kit = BTreeMap::new();
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

        let mut sockets_by_kit: BTreeMap<String, SocketCatalog> = BTreeMap::new();
        for kit in &kits {
            if kit.kit_id.is_empty() {
                continue;
            }
            let dir = root.join(SOCKET_CONTRACTS_PARENT).join(&kit.kit_id);
            if !dir.is_dir() {
                continue;
            }
            match SocketCatalog::load_dir(&dir) {
                Ok(cat) => {
                    sockets_by_kit.insert(kit.kit_id.clone(), cat);
                }
                Err(e) => errors.push(format!("{SOCKET_CONTRACTS_PARENT}/{}: {e}", kit.kit_id)),
            }
        }
        if !palettes.sockets.modules.is_empty() {
            sockets_by_kit
                .entry(PRIMARY_KIT.to_string())
                .or_insert_with(|| palettes.sockets.clone());
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
        self.sockets_by_kit = sockets_by_kit;
        self.data = Some(palettes);
        content_root_result(errors.is_empty(), &kit_ids, item_count, &errors)
    }

    /// Grouped palettes for the builder UI.
    #[func]
    fn palettes(&mut self) -> VarDictionary {
        self.ensure_palettes();
        palettes_to_dict(
            self.data.as_ref().expect("palettes initialized"),
            &self.extra_kits,
        )
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

    /// Fail-closed playable export. `{layout_json, gameplay_slice_json, error}`.
    #[func]
    fn export_playable(&mut self, golden_dict: VarDictionary, kit_id: GString) -> VarDictionary {
        self.ensure_palettes();
        match golden_from_dict(&golden_dict) {
            Err(e) => {
                godot::global::godot_error!("DerelictAuthor.export_playable: {e}");
                export_error_dict(&e)
            }
            Ok(mut golden) => {
                let kit = kit_id.to_string();
                if !kit.is_empty() {
                    golden.kit_id = kit;
                }
                match layout_from_golden(&golden) {
                    Err(e) => {
                        godot::global::godot_error!("DerelictAuthor.export_playable: {e}");
                        export_error_dict(&e)
                    }
                    Ok(docs) => {
                        let layout = serde_json::to_string_pretty(&docs.layout)
                            .unwrap_or_else(|_| String::new());
                        let slice = serde_json::to_string_pretty(&docs.gameplay_slice)
                            .unwrap_or_else(|_| String::new());
                        let mut d = VarDictionary::new();
                        d.set("layout_json", layout.as_str());
                        d.set("gameplay_slice_json", slice.as_str());
                        d.set("error", "");
                        d
                    }
                }
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
        let sockets = &self.data.as_ref().expect("palettes initialized").sockets;
        let catalog = (!sockets.modules.is_empty()).then_some(sockets);
        let ids = legal_module_ids(catalog, &kind.to_string(), &state.to_string());
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

fn export_error_dict(msg: &str) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("layout_json", "");
    d.set("gameplay_slice_json", "");
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
        &json_to_dict(&structural_plan_to_json(&out.plan, &|id| {
            name_of(id, &out.golden_ids)
        })),
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

fn cell3(x: i32, y: i32, deck: u8) -> Value {
    json!([x, y, deck])
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

pub(crate) fn legal_module_ids(
    catalog: Option<&SocketCatalog>,
    kind: &str,
    state: &str,
) -> Vec<String> {
    let kind = kind.trim().to_ascii_lowercase();
    let state = state.trim();
    let state_l = state.to_ascii_lowercase();
    let (required, preferred): (&[&str], &str) = match kind.as_str() {
        "floor" => {
            let connective =
                state_l == "connective" || Role::parse(&state_l).is_some_and(Role::is_connective);
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

fn array_variant_to_json(v: &Variant) -> Result<Value, String> {
    if let Ok(arr) = v.try_to::<VarArray>() {
        let mut out = Vec::new();
        for x in arr.iter_shared() {
            out.push(variant_to_json(&x)?);
        }
        return Ok(Value::Array(out));
    }
    // GDScript `Array[Dictionary]` is a typed array; godot-rust rejects it as VarArray.
    if let Ok(arr) = v.try_to::<Array<VarDictionary>>() {
        let mut out = Vec::new();
        for d in arr.iter_shared() {
            out.push(dict_to_json(&d)?);
        }
        return Ok(Value::Array(out));
    }
    Err(format!("cannot convert array to JSON: {v}"))
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
        VariantType::ARRAY => array_variant_to_json(v),
        VariantType::DICTIONARY => {
            let d: VarDictionary = v.try_to().map_err(|e| e.to_string())?;
            dict_to_json(&d)
        }
        other => Err(format!("unsupported variant type {other:?}")),
    }
}

const FLOAT_KEYS: &[&str] = &["yaw_degrees", "position", "allowed_yaw_deg"];

fn json_to_dict(value: &Value) -> VarDictionary {
    let mut d = VarDictionary::new();
    let Some(obj) = value.as_object() else {
        return d;
    };
    for (k, v) in obj {
        d.set(k.as_str(), &json_to_variant_keyed(Some(k.as_str()), v));
    }
    d
}

fn json_to_variant(value: &Value) -> Variant {
    json_to_variant_keyed(None, value)
}

fn json_to_variant_keyed(key: Option<&str>, value: &Value) -> Variant {
    let as_float = key.is_some_and(|k| FLOAT_KEYS.contains(&k));
    match value {
        Value::Null => Variant::nil(),
        Value::Bool(b) => b.to_variant(),
        Value::Number(n) if as_float => n.as_f64().unwrap_or(0.0).to_variant(),
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
        Value::Array(a) if as_float => {
            let mut arr = VarArray::new();
            for x in a {
                arr.push(&json_to_variant_keyed(key, x));
            }
            arr.to_variant()
        }
        Value::Array(a) => {
            let mut arr = VarArray::new();
            for x in a {
                arr.push(&json_to_variant_keyed(None, x));
            }
            arr.to_variant()
        }
        Value::Object(_) => json_to_dict(value).to_variant(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn every_role() -> impl Iterator<Item = Role> {
        use Role::*;
        [
            Airlock,
            Dock,
            Corridor,
            MainSpine,
            Hub,
            Ramp,
            Elevator,
            Bridge,
            Engineering,
            Reactor,
            LifeSupport,
            Maintenance,
            Cargo,
            Hangar,
            Storage,
            Armory,
            Security,
            Medical,
            CrewQuarters,
            MessHall,
            Compartment,
        ]
        .into_iter()
    }

    #[test]
    fn every_role_is_listed() {
        let listed: Vec<Role> = every_role().collect();
        assert_eq!(listed.len(), Role::ALL.len(), "every_role missed a variant");
        for role in Role::ALL {
            assert!(listed.contains(&role), "every_role missing {}", role.name());
        }
    }

    #[test]
    fn offline_floor_legal_matches_default_picker() {
        let picker = DefaultModulePicker;
        for role in every_role() {
            let ids = legal_module_ids(None, "floor", role.name());
            let expected = picker.floor(role.is_connective());
            assert_eq!(ids, vec![expected], "role {}", role.name());
        }
        assert_eq!(
            legal_module_ids(None, "floor", "connective"),
            vec![CORRIDOR_FLOOR_MODULE.to_string()]
        );
        assert_eq!(
            legal_module_ids(None, "floor", "ramp"),
            vec![CORRIDOR_FLOOR_MODULE.to_string()]
        );
        assert_eq!(
            legal_module_ids(None, "floor", "elevator"),
            vec![CORRIDOR_FLOOR_MODULE.to_string()]
        );
        assert_eq!(
            legal_module_ids(None, "floor", "bridge"),
            vec![FLOOR_MODULE.to_string()]
        );
    }
}
