//! Export a generated ship as The Synaptic Sea's `layout.json` (schema
//! 1.2.0, embedded structural_plan) plus a `gameplay_slice.json` — the exact
//! contract `GeneratedShipLoader.load_from_paths` consumes today. Field
//! shapes mirror the committed golden fixtures
//! (`data/procgen/golden/coherent_ship_001`).

use crate::model::{EntityKind, Ship};
use crate::role::Role;
use crate::stages::furnish::interior_zones;
use crate::structural::plan::{
    edge_key, Cell, DamageVariant, Dir, EdgeRecord, FloorPlacement, RoomId, StructuralPlan, NO_ROOM,
};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;

/// Stable, human-readable room id string ("airlock_01" style).
fn room_name(role: Role, id: RoomId) -> String {
    format!("{}_{:02}", role.name(), id)
}

fn cell2(c: Cell) -> Value {
    json!([c.x, c.y])
}

fn cell3(c: Cell) -> Value {
    json!([c.x, c.y, c.deck])
}

fn pos(p: [f32; 3]) -> Value {
    json!([p[0], p[1], p[2]])
}

fn variant_name(v: DamageVariant) -> &'static str {
    match v {
        DamageVariant::Intact => "intact",
        DamageVariant::Damaged => "damaged",
        DamageVariant::Breached => "breached",
    }
}

/// `structural_plan` object shared by layout export and the authoring preview.
pub fn structural_plan_to_json(
    plan: &StructuralPlan,
    name_of: &impl Fn(RoomId) -> String,
) -> Value {
    let edge_json = |e: &EdgeRecord, with_placement_id: bool| -> Value {
        let mut m = Map::new();
        m.insert("id".into(), json!(format!("edge:{}", e.edge_key)));
        m.insert("key".into(), json!(e.edge_key));
        m.insert("edge_key".into(), json!(e.edge_key));
        m.insert("deck".into(), json!(e.cell.deck));
        m.insert("cell".into(), cell2(e.cell));
        m.insert("direction".into(), json!(e.direction.name()));
        m.insert(
            "opposite_direction".into(),
            json!(e.direction.opposite().name()),
        );
        m.insert(
            "source_cells".into(),
            json!([cell3(e.source_cells[0]), cell3(e.source_cells[1])]),
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
                    "cell": cell2(rec.cell),
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
            "cell": cell2(f.cell),
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

pub struct ExportOptions {
    pub kit_id: String,
    pub biome_id: String,
    pub difficulty_id: String,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            kit_id: "ship_structural_v0".into(),
            biome_id: String::new(),
            difficulty_id: String::new(),
        }
    }
}

pub fn to_layout_json(ship: &Ship, opts: &ExportOptions) -> Value {
    let names: BTreeMap<RoomId, String> = ship
        .topology
        .rooms
        .iter()
        .map(|r| (r.id, room_name(r.role, r.id)))
        .collect();
    let name_of = |id: RoomId| -> String {
        if id == NO_ROOM {
            String::new()
        } else {
            names.get(&id).cloned().unwrap_or_default()
        }
    };
    let zones = interior_zones(&ship.topology, &ship.plan);

    // --- rooms --------------------------------------------------------------
    let rooms: Vec<Value> = ship
        .topology
        .rooms
        .iter()
        .map(|room| {
            let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
            for c in &room.cells {
                x0 = x0.min(c.x);
                y0 = y0.min(c.y);
                x1 = x1.max(c.x);
                y1 = y1.max(c.y);
            }
            let placements: Vec<Value> = room
                .cells
                .iter()
                .filter_map(|c| {
                    let rec = ship.plan.occupancy.get(&c.key())?;
                    Some(json!({
                        "name": format!("floor_cell_x{}_z{}", c.x, c.y),
                        "module": rec.module_id,
                        "world_position": pos(c.world_pos()),
                    }))
                })
                .collect();
            let z = zones.get(&room.id);
            json!({
                "id": name_of(room.id),
                "room_role": room.role.name(),
                "deck": room.deck,
                "cells": room.cells.iter().map(|c| cell2(*c)).collect::<Vec<_>>(),
                "footprint": [x1 - x0 + 1, y1 - y0 + 1],
                "structural_placements": placements,
                "interior_zones": {
                    "reserved_cells": z.map(|z| z.reserved_cells.iter().map(|c| cell2(*c)).collect::<Vec<_>>()).unwrap_or_default(),
                    "wall_slots": z.map(|z| z.wall_slots.iter().map(|c| cell2(*c)).collect::<Vec<_>>()).unwrap_or_default(),
                    "center_slots": z.map(|z| z.center_slots.iter().map(|c| cell2(*c)).collect::<Vec<_>>()).unwrap_or_default(),
                },
            })
        })
        .collect();

    // --- portals + room links (interior only; exterior doors live as plan
    // edges, matching how the game's own serializer treats hull boundaries).
    let mut portals: Vec<Value> = Vec::new();
    let mut room_links: Vec<Value> = Vec::new();
    for p in &ship.topology.portals {
        if p.exterior || p.to_room == NO_ROOM {
            continue;
        }
        let Some(dir) = Dir::between(p.from_cell, p.to_cell) else {
            continue;
        };
        let key = edge_key(p.from_cell, dir);
        let module = ship
            .plan
            .edges
            .get(&key)
            .map(|e| e.module_id.clone())
            .unwrap_or_default();
        let id = format!("{}_to_{}", name_of(p.from_room), name_of(p.to_room));
        portals.push(json!({
            "id": id,
            "from_room": name_of(p.from_room),
            "to_room": name_of(p.to_room),
            "from_cell": cell2(p.from_cell),
            "to_cell": cell2(p.to_cell),
            "state": p.state.name(),
            "module_id": module,
            "edge_key": key,
            "deck": p.from_cell.deck,
            "direction": dir.name(),
            "opposite_direction": dir.opposite().name(),
            "required": true,
        }));
        room_links.push(json!({
            "id": id,
            "from_room": name_of(p.from_room),
            "to_room": name_of(p.to_room),
            "from_cell": cell3(p.from_cell),
            "to_cell": cell3(p.to_cell),
            "module_id": module,
        }));
    }

    let verticals: Vec<Value> = ship
        .topology
        .verticals
        .iter()
        .map(|v| {
            json!({
                "id": format!("{}_to_{}", name_of(v.from_room), name_of(v.to_room)),
                "type": "ladder",
                "module_id": "",
                "from_room": name_of(v.from_room),
                "to_room": name_of(v.to_room),
                "from_cell": cell3(v.from_cell),
                "to_cell": cell3(v.to_cell),
            })
        })
        .collect();

    let critical_path: Vec<Value> = ship
        .critical_path
        .iter()
        .map(|id| json!(name_of(*id)))
        .collect();

    let structural_plan = structural_plan_to_json(&ship.plan, &name_of);

    json!({
        "schema_version": "1.2.0",
        "document_kind": "ship_layout",
        "program_id": format!("worldgen-{}-{}", ship.archetype_id, ship.seed),
        "generator": {
            "name": "worldgen",
            "generator_version": ship.generator_version,
            "seed": ship.seed,
            "archetype_id": ship.archetype_id,
            "template_id": ship.template_id,
            "intactness_bp": ship.intactness,
            "cause_of_loss": format!("{:?}", ship.cause_of_loss),
            "fractured": ship.fractured,
        },
        "cell_size": 4.0,
        "kit_id": opts.kit_id,
        "biome_id": opts.biome_id,
        "difficulty_id": opts.difficulty_id,
        "hazard_source": "runtime",
        "rooms": rooms,
        "portals": portals,
        "room_links": room_links,
        "vertical_connections": verticals,
        "critical_path": critical_path,
        "prototype": {
            "start_room": name_of(ship.entry_room),
            "goal_room": name_of(ship.goal_room),
        },
        "landmarks": [],
        "encounters": [],
        "blocked_links": [],
        "fire_zones": [],
        "arc_zones": [],
        "breach_zones": [],
        "structural_plan": structural_plan,
    })
}

/// Companion gameplay slice (schema 1.1.0): loot containers from the ship's
/// container entities, objectives from the goal room.
pub fn to_gameplay_slice_json(ship: &Ship) -> Value {
    let names: BTreeMap<RoomId, String> = ship
        .topology
        .rooms
        .iter()
        .map(|r| (r.id, room_name(r.role, r.id)))
        .collect();
    let name_of = |id: RoomId| names.get(&id).cloned().unwrap_or_default();
    let room_at = |deck: u8, x: i32, y: i32| -> Option<RoomId> {
        ship.topology
            .rooms
            .iter()
            .find(|r| {
                r.cells
                    .iter()
                    .any(|c| c.deck == deck && c.x == x && c.y == y)
            })
            .map(|r| r.id)
    };

    let loot_containers: Vec<Value> = ship
        .entities
        .iter()
        .filter(|e| e.kind == EntityKind::Container && !e.tags.iter().any(|t| t == "debris_field"))
        .filter_map(|e| {
            let room = room_at(e.pos.deck, e.pos.x, e.pos.y)?;
            Some(json!({
                "id": format!("container_{}", e.id),
                "kind": e.proto,
                "room_id": name_of(room),
                "approach_cell": [e.pos.x, e.pos.y, e.pos.deck],
                "loot_table": "worldgen_seeded",
            }))
        })
        .collect();

    let critical_path: Vec<Value> = ship
        .critical_path
        .iter()
        .map(|id| json!(name_of(*id)))
        .collect();
    // Objective 1: reach the goal room (anchored to one of its floor cells).
    let mut objectives: Vec<Value> = Vec::new();
    if let Some(goal) = ship.topology.rooms.iter().find(|r| r.id == ship.goal_room) {
        if let Some(cell) = goal.cells.first() {
            objectives.push(json!({
                "id": format!("{}:reach_goal", name_of(goal.id)),
                "sequence": 1,
                "type": "reach_room",
                "kind": "single",
                "room_id": name_of(goal.id),
                "room_role": goal.role.name(),
                "semantic": "goal_room",
                "cell": [cell.x, cell.y, cell.deck],
                "approach_cell": [cell.x, cell.y, cell.deck],
                "approach_distance_cells": 1,
                "interactable": false,
            }));
        }
    }
    json!({
        "schema_version": "1.1.0",
        "document_kind": "ship_gameplay_slice",
        "program_id": format!("worldgen-{}-{}", ship.archetype_id, ship.seed),
        "start_room": name_of(ship.entry_room),
        "goal_room": name_of(ship.goal_room),
        "critical_path": critical_path,
        "fire_zones": [],
        "objectives": objectives,
        "loot_containers": loot_containers,
        "summary": format!(
            "worldgen {} seed {} intactness {:.2} ({:?})",
            ship.archetype_id,
            ship.seed,
            ship.intactness as f32 / 10_000.0,
            ship.cause_of_loss
        ),
    })
}
