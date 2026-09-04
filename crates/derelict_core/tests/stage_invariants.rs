//! Structural invariants that must hold for every generated ship.

use derelict_core::model::*;
use derelict_core::role::Role;
use derelict_core::{GenData, GenParams};
use std::collections::BTreeSet;

fn intact_ship(arch: &str, seed: u64, data: &GenData) -> Ship {
    let mut params = GenParams::new(arch);
    params.intactness_override = Some(10_000);
    derelict_core::generate_ship(seed, &params, data).unwrap()
}

#[test]
fn every_room_reachable_when_intact() {
    let data = GenData::default_bundle().unwrap();
    for arch in ["shuttle", "corvette", "freighter", "frigate"] {
        for seed in 0..10u64 {
            let ship = intact_ship(arch, seed, &data);
            // Start from the authored entry room (airlock or dock).
            let mut reached: BTreeSet<u16> = BTreeSet::from([ship.entry_room]);
            let entry_kind = ship
                .room_graph
                .nodes
                .iter()
                .find(|n| n.id == ship.entry_room)
                .map(|n| n.kind);
            assert!(
                matches!(entry_kind, Some(Role::Airlock) | Some(Role::Dock)),
                "{arch} seed {seed}: entry room is {entry_kind:?}"
            );
            loop {
                let before = reached.len();
                for e in &ship.room_graph.edges {
                    if reached.contains(&e.a) {
                        reached.insert(e.b);
                    }
                    if reached.contains(&e.b) {
                        reached.insert(e.a);
                    }
                }
                if reached.len() == before {
                    break;
                }
            }
            let unreached: Vec<_> = ship
                .room_graph
                .nodes
                .iter()
                .filter(|n| n.tile_count > 0 && !reached.contains(&n.id))
                .map(|n| (n.id, n.kind, n.deck, n.tile_count))
                .collect();
            assert!(
                unreached.is_empty(),
                "{arch} seed {seed}: unreachable rooms {unreached:?}"
            );
        }
    }
}

#[test]
fn airlocks_have_exterior_doors() {
    let data = GenData::default_bundle().unwrap();
    for arch in ["shuttle", "corvette", "freighter", "frigate"] {
        for seed in 0..10u64 {
            let ship = intact_ship(arch, seed, &data);
            let n = ship
                .entities
                .iter()
                .filter(|e| e.kind == EntityKind::Door && e.proto == "airlock_door")
                .count();
            assert!(n >= 1, "{arch} seed {seed}: no exterior airlock door");
        }
    }
}

#[test]
fn fracture_produces_two_fragments() {
    let data = GenData::default_bundle().unwrap();
    let mut fractured_seen = 0;
    for seed in 0..20u64 {
        let mut params = GenParams::new("frigate");
        params.intactness_override = Some(800);
        let ship = derelict_core::generate_ship(seed, &params, &data).unwrap();
        if !ship.fractured {
            continue;
        }
        fractured_seen += 1;
        assert_eq!(ship.fragments.len(), 2, "seed {seed}");
        assert!(
            !ship.fragments[0].rooms.is_empty() && !ship.fragments[1].rooms.is_empty(),
            "seed {seed}: empty fragment"
        );
        // The two fragments must not share rooms.
        let a: BTreeSet<u16> = ship.fragments[0].rooms.iter().copied().collect();
        let b: BTreeSet<u16> = ship.fragments[1].rooms.iter().copied().collect();
        assert!(a.is_disjoint(&b), "seed {seed}: fragments share rooms");
        // Debris field exists between the pieces.
        assert!(
            ship.damage_events
                .iter()
                .any(|e| e.kind == DamageEventKind::DebrisField),
            "seed {seed}: fractured but no debris field"
        );
    }
    assert!(
        fractured_seen >= 10,
        "fracture rate suspiciously low: {fractured_seen}/20"
    );
}

#[test]
fn repaired_interior_portals_have_runtime_door_entities_seed_two() {
    let data = GenData::default_bundle().unwrap();
    let mut params = GenParams::new("shuttle");
    params.intactness_override = Some(6_000);
    let ship = derelict_core::generate_ship(2, &params, &data).unwrap();
    let interior_portals: Vec<_> = ship
        .topology
        .portals
        .iter()
        .filter(|portal| {
            !portal.exterior
                && matches!(
                    portal.state,
                    derelict_core::structural::plan::EdgeKind::Door
                        | derelict_core::structural::plan::EdgeKind::Locked
                        | derelict_core::structural::plan::EdgeKind::Hatch
                )
        })
        .collect();
    assert!(
        !interior_portals.is_empty(),
        "seed 2 should contain an interior door-like portal"
    );
    for portal in interior_portals {
        let direction =
            derelict_core::structural::plan::Dir::between(portal.from_cell, portal.to_cell)
                .expect("door-like portal endpoints are adjacent");
        let edge_tag = format!(
            "edge:{}",
            derelict_core::structural::plan::edge_key(portal.from_cell, direction)
        );
        let has_endpoint_door = ship.entities.iter().any(|entity| {
            entity.kind == EntityKind::Door
                && entity.tags.iter().any(|tag| tag == &edge_tag)
                && [portal.from_cell, portal.to_cell]
                    .iter()
                    .any(|cell| entity.pos == GridPos::new(cell.x, cell.y, cell.deck))
        });
        assert!(
            has_endpoint_door,
            "seed 2: interior {:?} portal {} -> {} has no endpoint Door entity",
            portal.state,
            portal.from_cell.key(),
            portal.to_cell.key()
        );
    }
}

#[test]
fn interior_entities_stand_on_floor() {
    let data = GenData::default_bundle().unwrap();
    for arch in ["corvette", "frigate"] {
        for seed in 0..10u64 {
            let params = GenParams::new(arch);
            let ship = derelict_core::generate_ship(seed, &params, &data).unwrap();
            for e in &ship.entities {
                if e.kind == EntityKind::Door || e.tags.iter().any(|t| t == "debris_field") {
                    continue;
                }
                let layer = &ship.decks[e.pos.deck as usize].layer;
                assert!(
                    layer.floor_at(e.pos.x, e.pos.y).walkable(),
                    "{arch} seed {seed}: {} '{}' floating in void at {:?}",
                    e.id,
                    e.proto,
                    e.pos
                );
            }
        }
    }
}

#[test]
fn loot_is_per_container_deterministic() {
    let data = GenData::default_bundle().unwrap();
    let params = GenParams::new("freighter");
    let a = derelict_core::generate_ship(77, &params, &data).unwrap();
    let b = derelict_core::generate_ship(77, &params, &data).unwrap();
    for (ea, eb) in a.entities.iter().zip(b.entities.iter()) {
        assert_eq!(ea.id, eb.id);
        assert_eq!(
            ea.inventory, eb.inventory,
            "container {} loot differs",
            ea.id
        );
    }
}

#[test]
fn mutation_diff_roundtrip() {
    let data = GenData::default_bundle().unwrap();
    let params = GenParams::new("corvette");
    let mut ship = derelict_core::generate_ship(9, &params, &data).unwrap();
    let container_id = ship
        .entities
        .iter()
        .find(|e| e.kind == EntityKind::Container && !e.inventory.is_empty())
        .map(|e| e.id)
        .expect("a container with loot");
    let door_id = ship
        .entities
        .iter()
        .find(|e| e.kind == EntityKind::Door)
        .map(|e| e.id)
        .unwrap();

    let mut diff = ShipMutationDiff::for_ship(&ship);
    diff.container_inventory.insert(container_id, Vec::new()); // looted empty
    diff.door_open.insert(door_id, true);
    diff.removed_entities.insert(container_id + 1);

    // Serialize the diff (save file model) and reapply onto a fresh regen.
    let bytes = bincode::serde::encode_to_vec(&diff, bincode::config::standard()).unwrap();
    let (diff2, _): (ShipMutationDiff, usize) =
        bincode::serde::decode_from_slice(&bytes, bincode::config::standard()).unwrap();
    let mut fresh = derelict_core::generate_ship(9, &params, &data).unwrap();
    apply_diff(&mut fresh, &diff2);
    apply_diff(&mut ship, &diff);
    assert_eq!(ship, fresh, "regenerate+diff must equal mutated original");
    assert!(fresh.entity(container_id).unwrap().inventory.is_empty());
    assert!(fresh.entity(door_id).unwrap().open);
    assert!(fresh.entity(container_id + 1).is_none());
}
