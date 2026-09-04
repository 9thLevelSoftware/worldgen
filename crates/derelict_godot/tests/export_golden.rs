//! Golden-hash tests for the Synaptic Sea JSON export surface.
//!
//! The layout and gameplay JSON documents produced by `export_layout_json` and
//! `export_gameplay_slice_json` must be byte-stable for a given
//! (archetype, seed, intactness) tuple. Any intentional change requires
//! regenerating the hash file in the same commit (and bumping
//! GENERATOR_VERSION):
//!
//! ```text
//! UPDATE_GOLDEN=1 cargo test -p derelict_godot --test export_golden
//! ```

use derelict_core::structural::export::{to_gameplay_slice_json, to_layout_json, ExportOptions};
use derelict_core::{GenData, GenParams};
use std::fmt::Write as _;

const KIT_ID: &str = "ship_structural_v0";

/// (archetype, seed, intactness_override)
const CASES: &[(&str, u64, Option<u16>)] = &[
    ("shuttle", 1, Some(9500)),
    ("shuttle", 17, Some(6000)),
    ("shuttle", 99, Some(2000)),
    ("corvette", 7, Some(9500)),
    ("corvette", 42, Some(6000)),
    ("corvette", 1234, Some(2000)),
    ("freighter", 3, Some(9500)),
    ("freighter", 100, Some(6000)),
    ("freighter", 9999, Some(2000)),
];

fn golden_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/export_golden/hashes.txt")
}

fn compute() -> String {
    let data = GenData::default_bundle().unwrap();
    let mut out = String::new();
    for (arch, seed, intact) in CASES {
        let mut params = GenParams::new(arch);
        params.intactness_override = *intact;
        let ship = derelict_core::generate_ship(*seed, &params, &data).unwrap();

        let opts = ExportOptions {
            kit_id: KIT_ID.to_string(),
            ..Default::default()
        };
        let layout_json = serde_json::to_string(&to_layout_json(&ship, &opts)).unwrap();
        let gameplay_json = serde_json::to_string(&to_gameplay_slice_json(&ship)).unwrap();

        let layout_hash = blake3::hash(layout_json.as_bytes());
        let gameplay_hash = blake3::hash(gameplay_json.as_bytes());

        writeln!(
            out,
            "{arch} {seed} {:?} layout {} gameplay {}",
            intact,
            layout_hash.to_hex(),
            gameplay_hash.to_hex()
        )
        .unwrap();
    }
    out
}

#[test]
fn export_golden_hashes_match() {
    let current = compute();
    let path = golden_path();
    if std::env::var("UPDATE_GOLDEN").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &current).unwrap();
        eprintln!("export golden hashes updated at {}", path.display());
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|_| {
        panic!(
            "export golden hash file missing; run UPDATE_GOLDEN=1 cargo test -p derelict_godot --test export_golden"
        )
    });
    assert_eq!(
        committed.replace("\r\n", "\n"),
        current,
        "export JSON changed — if intentional, bump GENERATOR_VERSION and regenerate goldens"
    );
}

#[test]
fn freighter_424242_critical_path_exports_standing_passable_portals() {
    let data = GenData::default_bundle().unwrap();
    let mut params = GenParams::new("freighter");
    params.intactness_override = Some(6000);
    let ship = derelict_core::generate_ship(424242, &params, &data).unwrap();
    let layout = to_layout_json(
        &ship,
        &ExportOptions {
            kit_id: KIT_ID.to_string(),
            ..Default::default()
        },
    );

    let path = layout["critical_path"]
        .as_array()
        .expect("critical_path must be an array");
    assert!(!path.is_empty(), "critical_path must not be empty");
    let portals = layout["portals"]
        .as_array()
        .expect("portals must be an array");
    let standing = ["OPEN", "DOOR", "HATCH"];
    for pair in path.windows(2) {
        let from = pair[0].as_str().unwrap();
        let to = pair[1].as_str().unwrap();
        let portal = portals.iter().find(|portal| {
            (portal["from_room"].as_str() == Some(from) && portal["to_room"].as_str() == Some(to))
                || (portal["from_room"].as_str() == Some(to)
                    && portal["to_room"].as_str() == Some(from))
        });
        let portal =
            portal.unwrap_or_else(|| panic!("missing portal for critical-path hop {from} -> {to}"));
        assert!(
            standing.contains(&portal["state"].as_str().unwrap()),
            "critical-path hop {from} -> {to} is not standing-passable: {}",
            portal["state"]
        );
    }
}

#[test]
fn export_layout_has_required_keys() {
    let data = GenData::default_bundle().unwrap();
    let mut params = GenParams::new("shuttle");
    params.intactness_override = Some(9500);
    let ship = derelict_core::generate_ship(42, &params, &data).unwrap();
    let json = to_layout_json(
        &ship,
        &ExportOptions {
            kit_id: KIT_ID.to_string(),
            ..Default::default()
        },
    );
    let value: serde_json::Value = json;
    let obj = value.as_object().expect("layout must be a JSON object");

    assert!(obj.contains_key("schema_version"), "missing schema_version");
    assert!(obj.contains_key("cell_size"), "missing cell_size");
    assert!(obj.contains_key("rooms"), "missing rooms");
    assert!(obj.contains_key("portals"), "missing portals");
    assert!(obj.contains_key("room_links"), "missing room_links");
    assert!(
        obj.contains_key("structural_plan"),
        "missing structural_plan"
    );
    assert!(
        obj.contains_key("vertical_connections"),
        "missing vertical_connections"
    );
    assert!(obj.contains_key("critical_path"), "missing critical_path");
    assert!(obj.contains_key("prototype"), "missing prototype");

    let rooms = obj["rooms"].as_array().expect("rooms must be array");
    assert!(!rooms.is_empty(), "rooms must not be empty");

    let sp = obj["structural_plan"]
        .as_object()
        .expect("structural_plan must be object");
    assert!(sp.contains_key("placements"), "missing placements");
    assert!(
        sp.contains_key("floor_placements"),
        "missing floor_placements"
    );
    assert!(
        sp.contains_key("ceiling_placements"),
        "missing ceiling_placements"
    );
    assert!(sp.contains_key("occupancy"), "missing occupancy");
    assert!(sp.contains_key("edges"), "missing edges");
    assert!(
        sp.contains_key("socket_bindings"),
        "missing socket_bindings"
    );

    let floors = sp["floor_placements"]
        .as_array()
        .expect("floor_placements must be array");
    assert!(!floors.is_empty(), "floor_placements must not be empty");

    let bindings = sp["socket_bindings"]
        .as_array()
        .expect("socket_bindings must be array");
    assert!(!bindings.is_empty(), "socket_bindings must not be empty");
}

#[test]
fn export_gameplay_has_required_keys() {
    let data = GenData::default_bundle().unwrap();
    let mut params = GenParams::new("corvette");
    params.intactness_override = Some(6000);
    let ship = derelict_core::generate_ship(42, &params, &data).unwrap();
    let json = to_gameplay_slice_json(&ship);
    let value: serde_json::Value = json;
    let obj = value.as_object().expect("gameplay must be a JSON object");

    assert!(obj.contains_key("start_room"), "missing start_room");
    assert!(obj.contains_key("goal_room"), "missing goal_room");
    assert!(obj.contains_key("objectives"), "missing objectives");
    assert!(
        obj.contains_key("loot_containers"),
        "missing loot_containers"
    );

    let start = obj["start_room"]
        .as_str()
        .expect("start_room must be string");
    assert!(!start.is_empty(), "start_room must not be empty");

    let goal = obj["goal_room"].as_str().expect("goal_room must be string");
    assert!(!goal.is_empty(), "goal_room must not be empty");

    let objectives = obj["objectives"]
        .as_array()
        .expect("objectives must be array");
    assert!(!objectives.is_empty(), "objectives must not be empty");
}

#[test]
fn export_room_ids_are_strings() {
    let data = GenData::default_bundle().unwrap();
    let mut params = GenParams::new("freighter");
    params.intactness_override = Some(9500);
    let ship = derelict_core::generate_ship(42, &params, &data).unwrap();
    let json = to_layout_json(
        &ship,
        &ExportOptions {
            kit_id: KIT_ID.to_string(),
            ..Default::default()
        },
    );
    let value: serde_json::Value = json;
    let rooms = value["rooms"].as_array().unwrap();

    for room in rooms {
        let id = room["id"].as_str().expect("room id must be string");
        assert!(!id.is_empty(), "room id must not be empty");
        // Must be like "airlock_1", "corridor_2", etc.
        assert!(
            id.contains('_'),
            "room id '{}' must contain underscore separator",
            id
        );
    }
}

#[test]
fn export_edge_keys_are_normalized() {
    let data = GenData::default_bundle().unwrap();
    let mut params = GenParams::new("shuttle");
    params.intactness_override = Some(9500);
    let ship = derelict_core::generate_ship(42, &params, &data).unwrap();
    let json = to_layout_json(
        &ship,
        &ExportOptions {
            kit_id: KIT_ID.to_string(),
            ..Default::default()
        },
    );
    let value: serde_json::Value = json;
    let edges = value["structural_plan"]["edges"]
        .as_object()
        .expect("edges must be object");

    for key in edges.keys() {
        // Must match pattern: "deck|orientation|x|y"
        let parts: Vec<&str> = key.split('|').collect();
        assert_eq!(
            parts.len(),
            4,
            "edge_key '{}' must have 4 parts (deck|orientation|x|y)",
            key
        );
        assert!(
            parts[1] == "h" || parts[1] == "v",
            "edge_key '{}' orientation must be 'h' or 'v'",
            key
        );
    }
}
