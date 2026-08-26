//! GoldenArea DTO adapter and apply_module_overrides.

use derelict_core::authoring::{
    apply_module_overrides, compile_authored, GoldenArea, ModuleOverrides, StaleClass,
};
use derelict_core::structural::compile::{compile, DefaultModulePicker, WALL_MODULE};
use derelict_core::structural::plan::{Cell, EdgeKind, NO_ROOM};
use derelict_core::structural::validate::{validate, IssueCode, ValidationPolicy};
use derelict_core::Role;

const SAMPLE: &str = include_str!("../assets/golden_areas/airlock_2x2.json");

fn sample() -> GoldenArea {
    serde_json::from_str(SAMPLE).expect("sample golden_area json")
}

fn pre_damage() -> ValidationPolicy {
    ValidationPolicy::pre_damage(Vec::new())
}

#[test]
fn sample_json_deserializes() {
    let golden = sample();
    assert_eq!(golden.id, "airlock_2x2");
    assert_eq!(golden.schema_version, "1.0.0");
    assert_eq!(golden.document_kind, "golden_area");
    assert_eq!(golden.entry_room, "airlock_01");
    assert_eq!(golden.topology.rooms[0].stable_id, "airlock_01");
    assert_eq!(golden.topology.rooms[0].role, "airlock");
    assert_eq!(
        golden.topology.rooms[0].cells,
        vec![[0, 0], [1, 0], [0, 1], [1, 1]]
    );
    assert_eq!(golden.topology.portals[0].state, "DOOR");
    assert_eq!(golden.topology.portals[0].to_cell, [-1, 0, 0]);
    assert_eq!(
        golden
            .module_overrides
            .floors
            .get("0|0|0")
            .map(String::as_str),
        Some("floor_1x1")
    );
    assert_eq!(
        golden
            .module_overrides
            .edges
            .get("0|v|0|-1")
            .map(String::as_str),
        Some("doorway_frame_open_1x1")
    );
    assert_eq!(golden.props[0].proto, "suit_locker");
    assert_eq!(golden.props[0].inventory[0].item_id, "scrap_metal");
    assert_eq!(golden.props[0].inventory[0].qty, 2);
    assert_eq!(golden.room_vars["1"].oxygen_bp, 8500);
}

#[test]
fn to_topology_round_trips_occupancy_and_portals() {
    let golden = sample();
    let topo = golden.to_topology().expect("sample topology");
    assert_eq!(topo.rooms.len(), 1);
    assert_eq!(topo.rooms[0].id, 1);
    assert_eq!(topo.rooms[0].role, Role::Airlock);
    assert_eq!(topo.rooms[0].deck, 0);
    assert_eq!(
        topo.rooms[0].cells,
        vec![
            Cell::new(0, 0, 0),
            Cell::new(0, 1, 0),
            Cell::new(0, 0, 1),
            Cell::new(0, 1, 1),
        ]
    );
    assert_eq!(topo.portals.len(), 1);
    assert_eq!(topo.portals[0].from_room, 1);
    assert_eq!(topo.portals[0].to_room, NO_ROOM);
    assert_eq!(topo.portals[0].from_cell, Cell::new(0, 0, 0));
    assert_eq!(topo.portals[0].to_cell, Cell::new(0, -1, 0));
    assert_eq!(topo.portals[0].state, EdgeKind::Door);
    assert!(topo.portals[0].exterior);
    assert!(topo.verticals.is_empty());

    let dto = GoldenArea::from_topology(&topo, &golden.room_stable_ids()).unwrap();
    assert_eq!(dto.rooms[0].stable_id, "airlock_01");
    assert_eq!(dto.rooms[0].role, "airlock");
    assert_eq!(dto.rooms[0].cells, golden.topology.rooms[0].cells);
    assert_eq!(dto.portals[0].state, "DOOR");
    assert_eq!(
        dto.portals[0].from_cell,
        golden.topology.portals[0].from_cell
    );
    assert_eq!(dto.portals[0].to_cell, golden.topology.portals[0].to_cell);
    assert!(dto.portals[0].exterior);
    assert!(dto.verticals.is_empty());
}

#[test]
fn reserialize_preserves_stable_id_and_overrides() {
    let golden = sample();
    let json = serde_json::to_string(&golden).unwrap();
    let again: GoldenArea = serde_json::from_str(&json).unwrap();
    assert_eq!(again.topology.rooms[0].stable_id, "airlock_01");
    assert_eq!(again.module_overrides, golden.module_overrides);
}

#[test]
fn portal_states_accept_door_locked_hatch_breach() {
    for (state, kind) in [
        ("DOOR", EdgeKind::Door),
        ("LOCKED", EdgeKind::Locked),
        ("HATCH", EdgeKind::Hatch),
        ("BREACH", EdgeKind::Breach),
    ] {
        let mut golden = sample();
        golden.topology.portals[0].state = state.to_string();
        let topo = golden
            .to_topology()
            .unwrap_or_else(|e| panic!("{state} should load: {e}"));
        assert_eq!(topo.portals[0].state, kind, "{state}");
    }
}

#[test]
fn portal_states_reject_solid_and_open() {
    for state in ["SOLID", "OPEN"] {
        let mut golden = sample();
        golden.topology.portals[0].state = state.to_string();
        let err = golden.to_topology().expect_err(state);
        assert!(
            err.contains(state),
            "expected '{state}' in load error, got {err}"
        );
    }
}

#[test]
fn floor_override_validates_pre_damage() {
    let golden = sample();
    let topo = golden.to_topology().unwrap();
    let (plan, stale) = compile_authored(&topo, &DefaultModulePicker, &golden.module_overrides);
    assert!(stale.is_empty(), "stale: {stale:?}");
    assert!(plan.errors.is_empty(), "compiler errors: {:?}", plan.errors);
    assert_eq!(plan.occupancy["0|0|0"].module_id, "floor_1x1");
    assert_eq!(plan.occupancy["0|1|0"].module_id, "corridor_floor_1x1");
    let floor = plan
        .floor_placements
        .iter()
        .find(|f| f.cell_key == "0|0|0")
        .unwrap();
    assert_eq!(floor.module_id, "floor_1x1");
    validate(&plan, &topo, &pre_damage()).expect("overridden floors must validate");
}

#[test]
fn vertex_dressed_wall_override_survives_and_rebuilds_sockets() {
    let golden = sample();
    let topo = golden.to_topology().unwrap();
    let mut plan = compile(&topo, &DefaultModulePicker);
    let (key, previous) = plan
        .edges
        .iter()
        .find(|(_, e)| e.kind == EdgeKind::Solid && e.module_id != WALL_MODULE)
        .map(|(k, e)| (k.clone(), e.module_id.clone()))
        .expect("2x2 airlock should have a vertex-dressed wall");
    assert_ne!(previous, WALL_MODULE);

    let mut ov = ModuleOverrides::default();
    ov.edges.insert(key.clone(), WALL_MODULE.to_string());
    plan.socket_bindings.clear();
    let stale = apply_module_overrides(&mut plan, &ov);
    assert!(stale.is_empty(), "stale: {stale:?}");
    assert_eq!(plan.edges[&key].module_id, WALL_MODULE);
    assert!(
        plan.placements
            .iter()
            .any(|p| p.edge_key == key && p.module_id == WALL_MODULE),
        "overridden wall must be in rebuilt placements"
    );
    assert!(
        !plan.socket_bindings.is_empty(),
        "emit_socket_bindings must run after overrides"
    );
}

#[test]
fn stale_override_keys_are_dropped_not_plan_errors() {
    let golden = sample();
    let topo = golden.to_topology().unwrap();
    let mut plan = compile(&topo, &DefaultModulePicker);
    plan.errors.clear();

    let mut ov = ModuleOverrides::default();
    ov.floors.insert("9|9|9".into(), "floor_1x1".into());
    ov.ceilings.insert("8|8|8".into(), "ceiling_cap_1x1".into());
    ov.edges.insert("missing-edge".into(), WALL_MODULE.into());
    let stale = apply_module_overrides(&mut plan, &ov);
    assert_eq!(stale.len(), 3, "stale: {stale:?}");
    assert!(stale
        .iter()
        .any(|s| s.class == StaleClass::Floor && s.key == "9|9|9"));
    assert!(stale
        .iter()
        .any(|s| s.class == StaleClass::Ceiling && s.key == "8|8|8"));
    assert!(stale
        .iter()
        .any(|s| s.class == StaleClass::Edge && s.key == "missing-edge"));
    assert!(
        plan.errors.is_empty(),
        "stale keys must not become plan.errors"
    );
    assert!(!plan.occupancy.contains_key("9|9|9"));
}

#[test]
fn floor_2x1_override_emits_floor_bad_module() {
    let golden = sample();
    let topo = golden.to_topology().unwrap();
    let mut ov = golden.module_overrides.clone();
    ov.floors.insert("0|0|0".into(), "floor_2x1".into());
    let (plan, stale) = compile_authored(&topo, &DefaultModulePicker, &ov);
    assert!(stale.is_empty(), "stale: {stale:?}");
    assert_eq!(plan.occupancy["0|0|0"].module_id, "floor_2x1");
    assert_eq!(
        plan.floor_placements
            .iter()
            .find(|f| f.cell_key == "0|0|0")
            .unwrap()
            .module_id,
        "floor_2x1"
    );
    let issues = validate(&plan, &topo, &pre_damage()).expect_err("floor_2x1 must fail validate");
    assert!(
        issues.iter().any(|i| i.code == IssueCode::FloorBadModule),
        "expected FloorBadModule, got: {issues:?}"
    );
}

#[test]
fn empty_or_duplicate_stable_id_is_load_error() {
    let mut golden = sample();
    golden.topology.rooms[0].stable_id.clear();
    let err = golden.to_topology().expect_err("empty stable_id");
    assert!(err.contains("empty stable_id"), "{err}");

    let mut golden = sample();
    let mut dup = golden.topology.rooms[0].clone();
    dup.id = 2;
    dup.cells = vec![[2, 0]];
    golden.topology.rooms.push(dup);
    let err = golden.to_topology().expect_err("duplicate stable_id");
    assert!(err.contains("duplicate stable_id"), "{err}");
}
