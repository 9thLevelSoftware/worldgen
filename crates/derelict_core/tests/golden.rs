//! Golden-hash tests: generated ships for a committed set of inputs must
//! hash to committed values. Any intentional generation change requires
//! regenerating the hash file in the same commit (and bumping
//! GENERATOR_VERSION):
//!
//! ```text
//! UPDATE_GOLDEN=1 cargo test -p derelict_core --test golden
//! ```

use derelict_core::role::Role;
use derelict_core::structural::export::{to_layout_json, ExportOptions};
use derelict_core::{GenData, GenParams};
use std::fmt::Write as _;

const CASES: &[(&str, u64, Option<u16>)] = &[
    ("shuttle", 1, None),
    ("shuttle", 99, Some(2000)),
    ("corvette", 7, None),
    ("corvette", 1234, Some(9500)),
    ("freighter", 42, None),
    ("freighter", 8, Some(1500)),
    ("frigate", 3, None),
    ("frigate", 12, Some(600)),
];

fn golden_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/golden/hashes.txt")
}

fn compute() -> String {
    let data = GenData::default_bundle().unwrap();
    let mut out = String::new();
    for (arch, seed, intact) in CASES {
        let mut params = GenParams::new(arch);
        params.intactness_override = *intact;
        let ship = derelict_core::generate_ship(*seed, &params, &data).unwrap();
        let bytes = bincode::serde::encode_to_vec(&ship, bincode::config::standard()).unwrap();
        let hash = blake3::hash(&bytes);
        writeln!(out, "{arch} {seed} {:?} {}", intact, hash.to_hex()).unwrap();
    }
    out
}

#[test]
fn golden_hashes_match() {
    let current = compute();
    let path = golden_path();
    if std::env::var("UPDATE_GOLDEN").is_ok() {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, &current).unwrap();
        eprintln!("golden hashes updated at {}", path.display());
        return;
    }
    let committed = std::fs::read_to_string(&path).unwrap_or_else(|_| {
        panic!(
            "golden hash file missing; run UPDATE_GOLDEN=1 cargo test -p derelict_core --test golden"
        )
    });
    assert_eq!(
        committed.replace("\r\n", "\n"),
        current,
        "generated output changed — if intentional, bump GENERATOR_VERSION and regenerate goldens"
    );
}

fn stamped_shuttle_data() -> GenData {
    let mut data = GenData::default_bundle().unwrap();
    let arch = data.archetypes.get_mut("shuttle").unwrap();
    arch.golden_stamps = vec!["airlock_2x2".into()];
    arch.template = "compact".into();
    data
}

#[test]
fn default_archetypes_do_not_stamp() {
    let data = GenData::default_bundle().unwrap();
    for a in data.archetypes.values() {
        assert!(
            a.golden_stamps.is_empty(),
            "{} should not stamp until a fixture opts in",
            a.id
        );
    }
    let mut params = GenParams::new("shuttle");
    params.intactness_override = Some(10_000);
    let ship = derelict_core::generate_ship(1, &params, &data).unwrap();
    assert!(!ship
        .entities
        .iter()
        .any(|e| e.tags.iter().any(|t| t == "authored_prop")));
}

#[test]
fn stamps_airlock_2x2_via_compile_authored() {
    let data = stamped_shuttle_data();
    let mut params = GenParams::new("shuttle");
    params.intactness_override = Some(10_000);

    let mut stamped = None;
    for seed in 1..48u64 {
        let Ok(ship) = derelict_core::generate_ship(seed, &params, &data) else {
            continue;
        };
        let Some(airlock) = ship.topology.rooms.iter().find(|r| r.role == Role::Airlock) else {
            continue;
        };
        let has_override = airlock.cells.iter().any(|c| {
            ship.plan
                .occupancy
                .get(&c.key())
                .map(|rec| rec.module_id.as_str())
                == Some("floor_1x1")
        });
        if airlock.cells.len() == 4 && has_override {
            stamped = Some(ship);
            break;
        }
    }
    let ship = stamped.expect("airlock_2x2 should stamp onto a compact shuttle");

    let airlock = ship
        .topology
        .rooms
        .iter()
        .find(|r| r.role == Role::Airlock)
        .unwrap();
    assert_eq!(airlock.cells.len(), 4, "golden occupancy is 2x2");

    let locker = ship
        .entities
        .iter()
        .find(|e| e.tags.iter().any(|t| t == "authored_prop") && e.proto == "suit_locker")
        .expect("authored suit_locker survives furnish skip");
    assert_eq!(locker.inventory.len(), 1, "explicit inventory is preserved");
    assert_eq!(locker.inventory[0].qty, 2);

    let on_locker_cell = ship
        .entities
        .iter()
        .filter(|e| e.pos == locker.pos && e.kind != derelict_core::EntityKind::Door)
        .count();
    assert_eq!(on_locker_cell, 1, "furnish must skip AuthoredProp cells");

    let layout = to_layout_json(&ship, &ExportOptions::default());
    assert_eq!(
        layout["hazard_source"], "runtime",
        "generated ships keep runtime hazard_source"
    );
}

#[test]
fn incompatible_stamp_roles_are_skipped() {
    let mut data = stamped_shuttle_data();
    let mut golden = data.golden_areas.get("airlock_2x2").cloned().unwrap();
    golden.stamp.as_mut().unwrap().compatible_roles = vec!["bridge".into()];
    data.golden_areas.insert("airlock_2x2".into(), golden);

    let mut params = GenParams::new("shuttle");
    params.intactness_override = Some(10_000);
    let ship = derelict_core::generate_ship(1, &params, &data).unwrap();
    assert!(
        !ship
            .entities
            .iter()
            .any(|e| e.tags.iter().any(|t| t == "authored_prop")),
        "bridge-only stamp must skip airlock rooms"
    );
    let airlock = ship
        .topology
        .rooms
        .iter()
        .find(|r| r.role == Role::Airlock)
        .unwrap();
    let has_floor_1x1 = airlock.cells.iter().any(|c| {
        ship.plan
            .occupancy
            .get(&c.key())
            .map(|rec| rec.module_id.as_str())
            == Some("floor_1x1")
    });
    assert!(
        !has_floor_1x1,
        "skipped stamp must not apply module_overrides"
    );
}
