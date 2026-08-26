//! Playable layout.json + gameplay_slice.json export from GoldenArea.

use derelict_core::authoring::GoldenArea;
use derelict_core::structural::export::layout_from_golden;
use derelict_core::structural::validate::FLOOR_MODULES;
use serde_json::Value;
use std::path::PathBuf;

const SAMPLE: &str = include_str!("../assets/golden_areas/airlock_2x2.json");

fn sample() -> GoldenArea {
    serde_json::from_str(SAMPLE).expect("sample golden_area json")
}

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/golden_areas/airlock_2x2")
}

#[test]
fn airlock_2x2_exports_playable_docs() {
    let docs = layout_from_golden(&sample()).expect("airlock_2x2 must export");
    assert_layout_contract(&docs.layout);
    assert_slice_contract(&docs.gameplay_slice);
    assert_overlays(&docs.layout, &docs.gameplay_slice);
}

#[test]
fn airlock_2x2_committed_fixture_matches_export() {
    let docs = layout_from_golden(&sample()).expect("airlock_2x2 must export");
    let dir = fixture_dir();
    let layout_path = dir.join("layout.json");
    let slice_path = dir.join("gameplay_slice.json");
    if std::env::var("UPDATE_GOLDEN").is_ok() {
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            &layout_path,
            serde_json::to_string_pretty(&docs.layout).unwrap() + "\n",
        )
        .unwrap();
        std::fs::write(
            &slice_path,
            serde_json::to_string_pretty(&docs.gameplay_slice).unwrap() + "\n",
        )
        .unwrap();
        return;
    }
    let committed_layout: Value = serde_json::from_str(
        &std::fs::read_to_string(&layout_path)
            .unwrap_or_else(|_| panic!("missing {}; run UPDATE_GOLDEN=1", layout_path.display())),
    )
    .unwrap();
    let committed_slice: Value = serde_json::from_str(
        &std::fs::read_to_string(&slice_path)
            .unwrap_or_else(|_| panic!("missing {}; run UPDATE_GOLDEN=1", slice_path.display())),
    )
    .unwrap();
    assert_eq!(committed_layout, docs.layout, "layout.json fixture drift");
    assert_eq!(
        committed_slice, docs.gameplay_slice,
        "gameplay_slice.json fixture drift"
    );
}

#[test]
fn floor_bad_module_refuses_export() {
    let mut golden = sample();
    golden
        .module_overrides
        .floors
        .insert("0|0|0".into(), "floor_2x1".into());
    let err = layout_from_golden(&golden).expect_err("floor_2x1 must refuse");
    assert!(
        err.contains("FloorBadModule"),
        "expected FloorBadModule, got {err}"
    );
}

#[test]
fn unresolved_entry_refuses_export() {
    let mut golden = sample();
    golden.entry_room = "missing_room".into();
    let err = layout_from_golden(&golden).expect_err("missing entry must refuse");
    assert!(
        err.contains("unresolved") || err.contains("missing_room"),
        "{err}"
    );
}

#[test]
fn missing_goal_defaults_to_entry_for_room_scope() {
    let mut golden = sample();
    golden.goal_room.clear();
    let docs = layout_from_golden(&golden).expect("room scope defaults goal to entry");
    assert_eq!(docs.layout["prototype"]["goal_room"], "airlock_01");
    assert_eq!(docs.gameplay_slice["goal_room"], "airlock_01");
}

#[test]
fn derelict_scope_requires_entry_and_goal() {
    let mut golden = sample();
    golden.scope = derelict_core::authoring::GoldenScope::Derelict;
    golden.goal_room.clear();
    let err = layout_from_golden(&golden).expect_err("derelict requires goal");
    assert!(err.contains("derelict"), "{err}");
}

/// StructuralPlanValidator-equivalent: string room ids on layout + plan.
fn assert_layout_contract(layout: &Value) {
    assert_eq!(layout["schema_version"], "1.2.0");
    assert_eq!(layout["document_kind"], "ship_layout");
    assert_eq!(layout["generator"]["name"], "derelict_builder");
    assert_eq!(layout["hazard_source"], "authored");
    assert_eq!(layout["generator"]["archetype_id"], "golden");
    assert_eq!(layout["generator"]["template_id"], "airlock_2x2");
    assert_eq!(layout["generator"]["seed"], 0);

    let rooms = layout["rooms"].as_array().expect("rooms array");
    assert_eq!(rooms.len(), 1);
    let room_id = rooms[0]["id"].as_str().expect("room id string");
    assert_eq!(room_id, "airlock_01");
    assert_eq!(rooms[0]["room_role"], "airlock");
    assert_eq!(rooms[0]["depressurized"], false);
    assert_eq!(rooms[0]["atmosphere_bp"], 8500);

    let portals = layout["portals"].as_array().expect("portals array present");
    assert!(
        portals.is_empty(),
        "interior-only portals; exterior airlock door stays a plan edge, got {portals:?}"
    );

    let plan = layout["structural_plan"]
        .as_object()
        .expect("structural_plan");
    let occupancy = plan["occupancy"].as_object().expect("occupancy");
    assert!(!occupancy.is_empty());
    for (_k, rec) in occupancy {
        let rid = rec["room_id"].as_str().expect("occupancy room_id string");
        assert_eq!(rid, room_id);
    }
    let floors = plan["floor_placements"]
        .as_array()
        .expect("floor_placements");
    assert_eq!(floors.len(), 4);
    for f in floors {
        let rid = f["room_id"].as_str().expect("floor room_id string");
        assert_eq!(rid, room_id);
        let module = f["module_id"].as_str().expect("floor module_id");
        assert!(
            FLOOR_MODULES.contains(&module),
            "floor module {module} not in FLOOR_MODULES"
        );
        assert!(f["cell"].as_array().is_some_and(|c| c.len() == 2));
        assert!(f["yaw_degrees"].is_number());
        let key = f["cell_key"].as_str().expect("cell_key");
        assert!(key.contains('|'), "cell_key {key}");
    }

    assert!(layout["prototype"]["start_room"].as_str() == Some("airlock_01"));
    assert!(layout["prototype"]["goal_room"].as_str() == Some("airlock_01"));
}

fn assert_slice_contract(slice: &Value) {
    assert_eq!(slice["schema_version"], "1.1.0");
    assert_eq!(slice["start_room"], "airlock_01");
    assert_eq!(slice["goal_room"], "airlock_01");
    let objectives = slice["objectives"].as_array().expect("objectives");
    assert_eq!(objectives.len(), 1);
    assert_eq!(objectives[0]["id"], "airlock_01:reach_goal");
    assert_eq!(objectives[0]["sequence"], 1);
    assert_eq!(objectives[0]["type"], "reach_room");
    assert_eq!(objectives[0]["room_id"], "airlock_01");
    let approach = objectives[0]["approach_cell"]
        .as_array()
        .expect("approach_cell");
    assert!(
        approach.len() >= 3,
        "approach_cell must be [x,y,deck], got {approach:?}"
    );

    let loot = slice["loot_containers"]
        .as_array()
        .expect("loot_containers");
    assert_eq!(loot.len(), 1);
    assert_eq!(loot[0]["kind"], "suit_locker");
    assert_eq!(loot[0]["room_id"], "airlock_01");
    let cell = loot[0]["approach_cell"].as_array().expect("loot approach");
    assert_eq!(cell.len(), 3);
    assert_eq!(cell[0], 0);
    assert_eq!(cell[1], 1);
    assert_eq!(cell[2], 0);
    let contents = loot[0]["contents"].as_array().expect("explicit contents");
    assert_eq!(contents.len(), 1);
    assert_eq!(contents[0]["item_id"], "scrap_metal");
    assert_eq!(contents[0]["qty"], 2);
}

fn assert_overlays(layout: &Value, slice: &Value) {
    assert!(layout["fire_zones"].as_array().unwrap().is_empty());
    assert!(layout["arc_zones"].as_array().unwrap().is_empty());
    assert!(layout["breach_zones"].as_array().unwrap().is_empty());
    assert!(slice["fire_zones"].as_array().unwrap().is_empty());
}
