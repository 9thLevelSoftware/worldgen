//! Authored prop placement identity must survive playable export.

use derelict_core::authoring::{AuthoredProp, GoldenArea, InventoryMode};
use derelict_core::model::EntityKind;
use derelict_core::structural::export::layout_from_golden;
use serde_json::Value;

const SAMPLE: &str = include_str!("../assets/golden_areas/airlock_2x2.json");

fn sample() -> GoldenArea {
    serde_json::from_str(SAMPLE).expect("sample golden area")
}

fn row<'a>(rows: &'a [Value], id: &str) -> &'a Value {
    rows.iter()
        .find(|row| row["id"] == id)
        .unwrap_or_else(|| panic!("missing placed prop {id}: {rows:?}"))
}

#[test]
fn furniture_and_container_placement_identity_survive_export() {
    let mut golden = sample();
    golden.props[0].inventory_mode = InventoryMode::Empty;
    golden.props[0].inventory.clear();
    golden.props.push(AuthoredProp {
        id: 7,
        kind: EntityKind::Furniture,
        proto: "bench_fixture".into(),
        visual_id: "industrial_bench".into(),
        cell: [1, 0, 0],
        rotation: 3,
        facing: Some("north".into()),
        locked: false,
        inventory_mode: InventoryMode::Empty,
        inventory: Vec::new(),
        loot_table: None,
    });
    golden.props.push(AuthoredProp {
        id: 8,
        kind: EntityKind::Container,
        proto: "cargo_bin".into(),
        visual_id: "cargo_bin_large".into(),
        cell: [0, 0, 0],
        rotation: 1,
        facing: Some("west".into()),
        locked: true,
        inventory_mode: InventoryMode::Explicit,
        inventory: vec![derelict_core::authoring::AuthoredStack {
            item_id: "scrap_metal".into(),
            qty: 4,
        }],
        loot_table: None,
    });

    let docs = layout_from_golden(&golden).expect("authored props export");
    let rows = docs.gameplay_slice["placed_props"]
        .as_array()
        .expect("placed_props array");
    assert_eq!(rows.len(), 3);

    let furniture = row(rows, "prop_7");
    assert_eq!(furniture["kind"], "Furniture");
    assert_eq!(furniture["proto"], "bench_fixture");
    assert_eq!(furniture["visual_id"], "industrial_bench");
    assert_eq!(furniture["room_id"], "airlock_01");
    assert_eq!(furniture["cell"], serde_json::json!([1, 0, 0]));
    assert_eq!(furniture["approach_cell"], serde_json::json!([1, 0, 0]));
    assert_eq!(furniture["rotation"], 3);
    assert_eq!(furniture["facing"], "north");
    assert_eq!(furniture["inventory_mode"], "empty");
    assert_eq!(furniture["contents"], serde_json::json!([]));

    let empty = row(rows, "prop_1");
    assert_eq!(empty["kind"], "Container");
    assert_eq!(empty["inventory_mode"], "empty");
    assert_eq!(empty["cell"], serde_json::json!([0, 1, 0]));
    assert_eq!(empty["contents"], serde_json::json!([]));

    let explicit = row(rows, "prop_8");
    assert_eq!(explicit["kind"], "Container");
    assert_eq!(explicit["room_id"], "airlock_01");
    assert_eq!(explicit["rotation"], 1);
    assert_eq!(explicit["proto"], "cargo_bin");
    assert_eq!(explicit["inventory_mode"], "explicit");
    assert_eq!(explicit["contents"][0]["item_id"], "scrap_metal");
    assert_eq!(explicit["contents"][0]["qty"], 4);
    assert_eq!(explicit["loot_table"], Value::Null);

    // Loot interaction remains a separate authoritative projection.
    let loot = docs.gameplay_slice["loot_containers"]
        .as_array()
        .expect("loot_containers");
    assert!(loot
        .iter()
        .any(|entry| entry["approach_cell"] == serde_json::json!([0, 0, 0])));
}
