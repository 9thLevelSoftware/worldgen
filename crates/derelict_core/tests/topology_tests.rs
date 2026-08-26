//! Phase 2 verification: template loading + cross-validation, and zone-tree
//! placement into hull masks — every template must place, connect, compile,
//! and validate across a spread of seeds.

use derelict_core::authoring::{compile_authored, GoldenArea};
use derelict_core::rng;
use derelict_core::role::Role;
use derelict_core::stages::hull::Mask;
use derelict_core::structural::compile::{compile, DefaultModulePicker};
use derelict_core::structural::plan::{Cell, EdgeKind, PortalIntent, RoomSpec, Topology, NO_ROOM};
use derelict_core::structural::validate::{validate, ValidationPolicy};
use derelict_core::topology::{
    apply_golden_stamps, place_topology, remap_stamp_for_drift, PlacedTopology, RoleParams,
    TemplateSet,
};
use std::collections::{BTreeMap, BTreeSet};

fn rect_masks(width: u16, height: u16, decks: usize) -> Vec<Mask> {
    let mut masks = Vec::new();
    for _ in 0..decks {
        let mut m = Mask::new(width, height);
        for y in 1..height as i32 - 1 {
            for x in 1..width as i32 - 1 {
                m.set(x, y, true);
            }
        }
        masks.push(m);
    }
    masks
}

fn params() -> RoleParams {
    RoleParams {
        weights: Default::default(),
        guaranteed: vec![],
        max_duplicates: 3,
    }
}

#[test]
fn all_templates_load_and_validate() {
    let set = TemplateSet::default_bundle().expect("templates parse and validate");
    assert_eq!(
        set.templates.len(),
        13,
        "all 13 Synaptic Sea templates ported"
    );
}

#[test]
fn template_compatibility_filters_guarantees() {
    let set = TemplateSet::default_bundle().unwrap();
    // Dock exists only in derelict_a, derelict_b, hangar_wing — the exact
    // bug class from The Synaptic Sea (silently skipped dock) becomes a
    // selection-time filter here.
    let dock_capable = set.compatible(&[Role::Dock], 1);
    let ids: BTreeSet<&str> = dock_capable.iter().map(|t| t.id.as_str()).collect();
    assert_eq!(
        ids,
        BTreeSet::from(["derelict_a", "derelict_b", "hangar_wing"]),
        "dock guarantee must filter to dock-capable templates"
    );
    // Multi-deck templates are excluded when the hull has one deck.
    assert!(set
        .compatible(&[], 1)
        .iter()
        .all(|t| t.max_zone_deck() == 0));
    assert!(set.compatible(&[], 3).iter().any(|t| t.id == "stacked_v2"));
}

#[test]
fn every_template_places_and_validates() {
    let set = TemplateSet::default_bundle().unwrap();
    let p = params();
    let mut failures: Vec<String> = Vec::new();
    for template in set.templates.values() {
        let decks = (template.max_zone_deck() + 1) as usize;
        for seed in 0..8u64 {
            let masks = rect_masks(24, 14, decks);
            let mut r = rng::stream(seed, "topo_test", 0);
            let placed = match place_topology(&mut r, template, &masks, &p) {
                Ok(pt) => pt,
                Err(e) => {
                    failures.push(format!("{} seed {seed}: {e}", template.id));
                    continue;
                }
            };
            // Rooms don't overlap (compile would error, but assert here too).
            let mut seen = BTreeSet::new();
            for room in &placed.topology.rooms {
                for c in &room.cells {
                    assert!(
                        seen.insert(c.key()),
                        "{} seed {seed}: overlap at {}",
                        template.id,
                        c.key()
                    );
                }
            }
            // Critical path runs entry -> goal.
            assert_eq!(placed.critical_path.first(), Some(&placed.entry_room));
            assert_eq!(placed.critical_path.last(), Some(&placed.goal_room));
            // Exactly one exterior door.
            let exterior = placed
                .topology
                .portals
                .iter()
                .filter(|p| p.exterior)
                .count();
            assert_eq!(exterior, 1, "{} seed {seed}", template.id);
            // Full structural compile + fail-closed validation.
            let plan = compile(&placed.topology, &DefaultModulePicker);
            assert!(
                plan.errors.is_empty(),
                "{} seed {seed}: {:?}",
                template.id,
                plan.errors
            );
            let policy = ValidationPolicy::pre_damage(placed.critical_path.clone());
            if let Err(issues) = validate(&plan, &placed.topology, &policy) {
                failures.push(format!(
                    "{} seed {seed}: validation {:?}",
                    template.id,
                    issues.iter().take(3).collect::<Vec<_>>()
                ));
            }
        }
    }
    assert!(
        failures.is_empty(),
        "placement failures:\n{}",
        failures.join("\n")
    );
}

#[test]
fn guaranteed_role_is_forced_into_plan() {
    let set = TemplateSet::default_bundle().unwrap();
    let template = &set.templates["derelict_a"];
    let mut p = params();
    p.guaranteed = vec![Role::Dock];
    for seed in 0..20u64 {
        let masks = rect_masks(24, 14, 1);
        let mut r = rng::stream(seed, "topo_guarantee", 0);
        let placed = place_topology(&mut r, template, &masks, &p).expect("placement");
        assert!(
            placed
                .topology
                .rooms
                .iter()
                .any(|room| room.role == Role::Dock),
            "seed {seed}: dock guarantee not enforced"
        );
    }
}

#[test]
fn hazard_comfort_never_adjacent() {
    let set = TemplateSet::default_bundle().unwrap();
    let p = params();
    for template in set.templates.values() {
        let decks = (template.max_zone_deck() + 1) as usize;
        for seed in 0..8u64 {
            let masks = rect_masks(24, 14, decks);
            let mut r = rng::stream(seed, "topo_hazard", 0);
            let Ok(placed) = place_topology(&mut r, template, &masks, &p) else {
                continue;
            };
            // Re-derive adjacency from cells and assert the invariant.
            let mut owner = std::collections::BTreeMap::new();
            for room in &placed.topology.rooms {
                for c in &room.cells {
                    owner.insert((c.deck, c.x, c.y), room.id);
                }
            }
            for room in &placed.topology.rooms {
                if !room.role.is_hazardous() {
                    continue;
                }
                for c in &room.cells {
                    for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                        let n = owner
                            .get(&(c.deck, c.x + dx, c.y + dy))
                            .copied()
                            .unwrap_or(NO_ROOM);
                        if n != NO_ROOM && n != room.id {
                            let other = placed.topology.room(n).unwrap();
                            assert!(
                                !other.role.is_crew_comfort(),
                                "{} seed {seed}: {:?} adjacent to {:?}",
                                template.id,
                                room.role,
                                other.role
                            );
                        }
                    }
                }
            }
        }
    }
}

fn airlock_2x2() -> GoldenArea {
    serde_json::from_str(include_str!("../assets/golden_areas/airlock_2x2.json")).unwrap()
}

fn west_airlock_placed() -> (PlacedTopology, Vec<Mask>) {
    let masks = rect_masks(12, 10, 1);
    let airlock_cells = vec![
        Cell::new(0, 4, 2),
        Cell::new(0, 5, 2),
        Cell::new(0, 4, 3),
        Cell::new(0, 5, 3),
    ];
    let corridor_cells = vec![
        Cell::new(0, 0, 2),
        Cell::new(0, 1, 2),
        Cell::new(0, 2, 2),
        Cell::new(0, 3, 2),
    ];
    let placed = PlacedTopology {
        topology: Topology {
            rooms: vec![
                RoomSpec {
                    id: 1,
                    role: Role::Airlock,
                    deck: 0,
                    cells: airlock_cells,
                },
                RoomSpec {
                    id: 2,
                    role: Role::Corridor,
                    deck: 0,
                    cells: corridor_cells,
                },
            ],
            portals: vec![
                PortalIntent {
                    from_room: 1,
                    to_room: 2,
                    from_cell: Cell::new(0, 4, 2),
                    to_cell: Cell::new(0, 3, 2),
                    state: EdgeKind::Door,
                    exterior: false,
                },
                PortalIntent {
                    from_room: 1,
                    to_room: NO_ROOM,
                    from_cell: Cell::new(0, 5, 2),
                    to_cell: Cell::new(0, 6, 2),
                    state: EdgeKind::Door,
                    exterior: true,
                },
            ],
            verticals: vec![],
        },
        zone_of_room: BTreeMap::from([(1, "entry".into()), (2, "spine".into())]),
        entry_room: 1,
        goal_room: 2,
        critical_path: vec![1, 2],
        room_links: vec![(1, 2)],
    };
    (placed, masks)
}

#[test]
fn stamp_airlock_2x2_translates_and_keeps_overrides() {
    let golden = airlock_2x2();
    let (mut placed, masks) = west_airlock_placed();
    let applied = apply_golden_stamps(&mut placed, &[&golden], &masks).unwrap();
    let airlock = placed.topology.rooms.iter().find(|r| r.id == 1).unwrap();
    assert_eq!(airlock.cells.len(), 4);
    assert!(applied.overrides.floors.values().any(|m| m == "floor_1x1"));
    assert_eq!(applied.props.len(), 1);
    assert!(applied.skip_furnish.contains(&(0, 4, 3)));

    let (plan, _stale) =
        compile_authored(&placed.topology, &DefaultModulePicker, &applied.overrides);
    assert!(plan.errors.is_empty(), "{:?}", plan.errors);
    let attach = Cell::new(0, 4, 2);
    assert_eq!(
        plan.occupancy
            .get(&attach.key())
            .map(|r| r.module_id.as_str()),
        Some("floor_1x1"),
        "compile_authored must keep stamped floor override"
    );
}

#[test]
fn stamp_skips_incompatible_roles() {
    let mut golden = airlock_2x2();
    golden.stamp.as_mut().unwrap().compatible_roles = vec!["bridge".into()];
    let (mut placed, masks) = west_airlock_placed();
    let applied = apply_golden_stamps(&mut placed, &[&golden], &masks).unwrap();
    assert!(applied.overrides.floors.is_empty());
    assert!(applied.props.is_empty());
}

#[test]
fn stamp_unknown_compatible_role_is_fail_closed() {
    let mut golden = airlock_2x2();
    golden.stamp.as_mut().unwrap().compatible_roles = vec!["Airlock".into()];
    let (mut placed, masks) = west_airlock_placed();
    let err = apply_golden_stamps(&mut placed, &[&golden], &masks).unwrap_err();
    assert!(err.to_string().contains("unknown compatible role"), "{err}");
}

#[test]
fn stamp_tries_attach_edges_beyond_first() {
    let mut golden = airlock_2x2();
    let meta = golden.stamp.as_mut().unwrap();
    meta.attach_edges.insert(
        0,
        derelict_core::authoring::AttachEdge {
            cell: [0, 0, 0],
            dir: "north".into(),
        },
    );
    let (mut placed, masks) = west_airlock_placed();
    let applied = apply_golden_stamps(&mut placed, &[&golden], &masks).unwrap();
    assert!(
        applied.overrides.floors.values().any(|m| m == "floor_1x1"),
        "second west attach_edge must still stamp"
    );
}

#[test]
fn stamp_overlap_is_topology_error() {
    let golden = airlock_2x2();
    let (mut placed, masks) = west_airlock_placed();
    placed.topology.rooms[0].cells = vec![Cell::new(0, 4, 2)];
    placed.topology.rooms.push(RoomSpec {
        id: 3,
        role: Role::Storage,
        deck: 0,
        cells: vec![Cell::new(0, 5, 2), Cell::new(0, 4, 3), Cell::new(0, 5, 3)],
    });
    let err = apply_golden_stamps(&mut placed, &[&golden], &masks).unwrap_err();
    assert!(
        err.to_string().contains("overlap") || err.to_string().contains("stamp"),
        "{err}"
    );
}

#[test]
fn remap_stamp_keeps_floor_override_after_fragment_drift() {
    let golden = airlock_2x2();
    let (mut placed, masks) = west_airlock_placed();
    let applied = apply_golden_stamps(&mut placed, &[&golden], &masks).unwrap();
    let pre = placed.topology.clone();
    let (dx, dy) = (3, 1);
    for room in &mut placed.topology.rooms {
        if room.id != 1 {
            continue;
        }
        for c in &mut room.cells {
            c.x += dx;
            c.y += dy;
        }
    }
    placed.topology.portals.retain(|p| p.exterior || p.to_room == NO_ROOM);
    for p in &mut placed.topology.portals {
        if p.from_room == 1 {
            p.from_cell.x += dx;
            p.from_cell.y += dy;
        }
        if p.to_room == 1 || p.from_room == 1 {
            p.to_cell.x += dx;
            p.to_cell.y += dy;
        }
    }
    let drift_of = BTreeMap::from([(1, (dx, dy))]);
    let (overrides, _hazards) = remap_stamp_for_drift(
        &applied.overrides,
        &applied.hazards,
        &pre,
        &placed.topology,
        &drift_of,
    )
    .unwrap();
    let (plan, stale) = compile_authored(&placed.topology, &DefaultModulePicker, &overrides);
    assert!(plan.errors.is_empty(), "{:?}", plan.errors);
    assert!(
        !stale
            .iter()
            .any(|s| s.key.contains('|') && s.module_id == "floor_1x1"),
        "floor override must not go stale after drift: {stale:?}"
    );
    let drifted_attach = Cell::new(0, 4 + dx, 2 + dy);
    assert_eq!(
        plan.occupancy
            .get(&drifted_attach.key())
            .map(|r| r.module_id.as_str()),
        Some("floor_1x1"),
        "floor_1x1 must sit on the drifted attach cell"
    );
}
