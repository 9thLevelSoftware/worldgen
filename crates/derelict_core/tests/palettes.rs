//! Builder palette ingest: kit catalog, gameplay props, proto map, offline items.

use derelict_core::authoring::{
    load_proto_visual_map, proto_visual, AuthorPalettes, BuilderKitCatalog, ComponentPaletteEntry,
    GameplayPropEntry, ItemPaletteEntry, VisualBindingIndex,
};
use derelict_core::structural::sockets::KitCatalog;
use derelict_core::Role;

const KIT_JSON: &str = r##"{"kit_id":"ship_structural_v0","modules":[{"module_id":"floor_1x1","module_family":"floor","footprint_cells":[1,1],"godot_wrapper_scene":"res://wrappers/floor_1x1.tscn"}]}"##;

const GAMEPLAY_PROPS_JSON: &str = r##"{"kit_id":"gameplay_prop_v0","props":{"loot_crate":{"mesh_path":"","primitive":"box","albedo":"#c88a35"}}}"##;

const VISUAL_BINDINGS_JSON: &str = r##"{"components":{"nav_console":{"asset_id":"nav_console","visual_scene_path":"res://nav.glb","placement":{"allowed_yaw_deg":[0.0,90.0]}}},"dressing":{"generic_crate":{"asset_id":"generic_crate","visual_scene_path":"res://crate.glb","placement":{"allowed_yaw_deg":[0.0],"surface":"floor"}}},"objectives":{}}"##;

const COMPONENTS_JSON: &str = r##"{"components":{"locker_wall":{"slot":"wall"}}}"##;

#[test]
fn builder_kit_catalog_keeps_family_and_footprint() {
    let kit = BuilderKitCatalog::from_json(KIT_JSON).expect("kit json");
    assert_eq!(kit.kit_id, "ship_structural_v0");
    let module = kit.module("floor_1x1").expect("floor_1x1");
    assert_eq!(module.module_family, "floor");
    assert_eq!(module.footprint_cells, vec![1, 1]);
    assert_eq!(module.godot_wrapper_scene, "res://wrappers/floor_1x1.tscn");

    let dropped: KitCatalog = serde_json::from_str(KIT_JSON).expect("KitCatalog");
    assert_eq!(dropped.kit_id, "ship_structural_v0");
    assert_eq!(dropped.modules.len(), 1);
    assert_eq!(dropped.modules[0].module_id, "floor_1x1");
    assert_eq!(
        dropped.modules[0].godot_wrapper_scene,
        "res://wrappers/floor_1x1.tscn"
    );
}

#[test]
fn gameplay_props_load_from_props_map_not_kit_catalog() {
    let props = GameplayPropEntry::load_map(GAMEPLAY_PROPS_JSON).expect("props map");
    let crate_prop = props.get("loot_crate").expect("loot_crate");
    assert_eq!(crate_prop.id, "loot_crate");
    assert!(crate_prop.mesh_path.is_empty());
    assert_eq!(crate_prop.primitive, "box");
    assert_eq!(crate_prop.albedo, "#c88a35");

    let as_kit: KitCatalog = serde_json::from_str(GAMEPLAY_PROPS_JSON).expect("KitCatalog");
    assert_eq!(as_kit.kit_id, "gameplay_prop_v0");
    assert!(
        as_kit.modules.is_empty(),
        "KitCatalog::load would drop the props map"
    );
}

#[test]
fn proto_visual_map_from_committed_asset() {
    let map = load_proto_visual_map().expect("committed proto_visual_map.json");
    assert_eq!(map.get("bunk").map(String::as_str), Some("generic_locker"));
    assert_eq!(
        map.get("helm_console").map(String::as_str),
        Some("nav_console")
    );
    assert_eq!(
        map.get("cargo_crate").map(String::as_str),
        Some("generic_crate")
    );
    assert_eq!(proto_visual("bunk").as_deref(), Some("generic_locker"));
    assert_eq!(
        proto_visual("suit_locker").as_deref(),
        Some("generic_locker")
    );
    assert!(proto_visual("captains_chair").is_none());
}

#[test]
fn offline_items_from_items_ron_by_name() {
    let items = ItemPaletteEntry::offline().expect("items.ron");
    let scrap = items.get("scrap_metal").expect("scrap_metal");
    assert_eq!(scrap.item_id, "scrap_metal");
    assert_eq!(scrap.display_name, "scrap_metal");
    assert!(!items.contains_key("hull_sealant"));
    assert!(!items.contains_key("1"));
}

#[test]
fn offline_palettes_include_furnishing_and_scrap_metal() {
    let palettes = AuthorPalettes::offline().expect("offline palettes");
    assert!(palettes.items.contains_key("scrap_metal"));
    assert!(!palettes.items.contains_key("hull_sealant"));
    assert_eq!(
        palettes.proto_visual.get("bunk").map(String::as_str),
        Some("generic_locker")
    );
    assert!(palettes.furnishing.rules.contains_key(&Role::Airlock));
    assert!(palettes.kit.modules.is_empty());
    assert!(palettes.gameplay_props.is_empty());
}

#[test]
fn visual_binding_buckets_and_components() {
    let visuals = VisualBindingIndex::from_json(VISUAL_BINDINGS_JSON).expect("visuals");
    let nav = visuals.components.get("nav_console").expect("nav_console");
    assert_eq!(nav.asset_id, "nav_console");
    assert_eq!(nav.visual_scene_path, "res://nav.glb");
    assert_eq!(nav.allowed_yaw_deg, vec![0.0, 90.0]);
    assert!(nav.surface.is_none());
    let crate_bind = visuals
        .dressing
        .get("generic_crate")
        .expect("generic_crate");
    assert_eq!(crate_bind.surface.as_deref(), Some("floor"));
    assert!(visuals.objectives.is_empty());

    let components = ComponentPaletteEntry::load_map(COMPONENTS_JSON).expect("components");
    assert_eq!(components["locker_wall"].id, "locker_wall");
    assert_eq!(components["locker_wall"].slot, "wall");
}
