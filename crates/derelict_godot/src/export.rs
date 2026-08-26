//! JSON document exports for the Synaptic Sea procgen consumer.
//!
//! The core generator deliberately keeps its model engine-neutral. This module
//! translates that model into the stable layout/gameplay document contracts
//! consumed by the Godot ship loader.

use derelict_core::model::{
    EdgeKind, EntityKind, FloorTile, RoomType, Ship, Side, WallEdge, NO_ROOM,
};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet, VecDeque};

const CELL_SIZE: i64 = 4;
const DECK_HEIGHT: i64 = 4;

#[derive(Clone, Debug)]
struct RoomInfo {
    numeric_id: u16,
    string_id: String,
    kind: RoomType,
    deck: u8,
    cells: Vec<(i32, i32)>,
}

#[derive(Clone, Debug)]
struct Boundary {
    deck: u8,
    cell: (i32, i32),
    neighbor: (i32, i32),
    direction: &'static str,
    edge_key: String,
}

#[derive(Clone, Debug)]
struct PortalInfo {
    edge_key: String,
    deck: u8,
    from_numeric: u16,
    to_numeric: u16,
    from_room: String,
    to_room: String,
    from_cell: (i32, i32),
    to_cell: (i32, i32),
    direction: &'static str,
    portal_type: &'static str,
    locked: bool,
}

#[derive(Clone, Debug)]
struct VerticalInfo {
    from_numeric: u16,
    to_numeric: u16,
    from_cell: (i32, i32),
    to_cell: (i32, i32),
    from_deck: u8,
    to_deck: u8,
}

#[derive(Clone, Debug)]
struct ExportContext {
    rooms: BTreeMap<u16, RoomInfo>,
    room_ids: BTreeMap<u16, String>,
    occupancy: BTreeMap<(u8, i32, i32), u16>,
    portals: Vec<PortalInfo>,
    portal_by_edge: BTreeMap<String, PortalInfo>,
    vertical_connections: Vec<VerticalInfo>,
}

/// Convert a generated ship into the Synaptic Sea `layout.json` document.
pub fn ship_to_layout_json(ship: &Ship, kit_id: &str) -> String {
    let context = build_context(ship);
    let value = layout_value(ship, kit_id, &context);
    serde_json::to_string(&value).expect("layout JSON document is serializable")
}

/// Convert a generated ship into the Synaptic Sea `gameplay_slice.json` document.
pub fn ship_to_gameplay_slice_json(ship: &Ship) -> String {
    let context = build_context(ship);
    let value = gameplay_slice_value(ship, &context);
    serde_json::to_string(&value).expect("gameplay slice JSON document is serializable")
}

fn build_context(ship: &Ship) -> ExportContext {
    let mut occupancy: BTreeMap<(u8, i32, i32), u16> = BTreeMap::new();
    for (deck_index, deck) in ship.decks.iter().enumerate() {
        let layer = &deck.layer;
        for y in 0..layer.height as i32 {
            for x in 0..layer.width as i32 {
                let room_id = layer.room_at(x, y);
                if room_id != NO_ROOM && layer.floor_at(x, y) != FloorTile::Void {
                    occupancy.insert((deck_index as u8, x, y), room_id);
                }
            }
        }
    }

    let mut counts: BTreeMap<RoomType, usize> = BTreeMap::new();
    let mut room_ids = BTreeMap::new();
    let mut rooms = BTreeMap::new();
    for node in &ship.room_graph.nodes {
        let index = counts.entry(node.kind).or_insert(0);
        *index += 1;
        let string_id = format!("{}_{}", room_role(node.kind), *index);
        room_ids.insert(node.id, string_id.clone());
        let mut cells: Vec<(i32, i32)> = occupancy
            .iter()
            .filter_map(|((deck, x, y), room_id)| {
                (*deck == node.deck && *room_id == node.id).then_some((*x, *y))
            })
            .collect();
        cells.sort_by_key(|(x, y)| (*y, *x));
        rooms.insert(
            node.id,
            RoomInfo {
                numeric_id: node.id,
                string_id,
                kind: node.kind,
                deck: node.deck,
                cells,
            },
        );
    }

    let mut boundary_by_pair: BTreeMap<(u16, u16), Vec<Boundary>> = BTreeMap::new();
    for ((deck, x, y), room_id) in &occupancy {
        let layer = &ship.decks[*deck as usize].layer;
        for (side, neighbor, direction, edge_key) in [
            (
                Side::North,
                (*x, *y - 1),
                "north",
                format!("{}|h|{}|{}", deck, y - 1, x),
            ),
            (
                Side::West,
                (*x - 1, *y),
                "west",
                format!("{}|v|{}|{}", deck, y, x - 1),
            ),
        ] {
            let _wall = layer.edge(*x, *y, side);
            if let Some(other_id) = occupancy.get(&(*deck, neighbor.0, neighbor.1)) {
                if other_id != room_id {
                    let pair = ordered_pair(*room_id, *other_id);
                    boundary_by_pair.entry(pair).or_default().push(Boundary {
                        deck: *deck,
                        cell: (*x, *y),
                        neighbor,
                        direction,
                        edge_key,
                    });
                }
            }
        }
    }
    for boundaries in boundary_by_pair.values_mut() {
        boundaries.sort_by_key(|b| (b.deck, b.cell.1, b.cell.0, b.edge_key.clone()));
    }

    let mut portals = Vec::new();
    for edge in &ship.room_graph.edges {
        if matches!(edge.kind, EdgeKind::VerticalShaft) {
            continue;
        }
        let pair = ordered_pair(edge.a, edge.b);
        let Some(boundary) = boundary_by_pair.get(&pair).and_then(|items| items.first()) else {
            continue;
        };
        let (from_cell, to_cell, direction) = if boundary.cell_room(&occupancy) == Some(edge.a) {
            (boundary.cell, boundary.neighbor, boundary.direction)
        } else {
            (
                boundary.neighbor,
                boundary.cell,
                opposite_direction(boundary.direction),
            )
        };
        let locked = matches!(edge.kind, EdgeKind::Door)
            && ship.entities.iter().any(|entity| {
                entity.kind == EntityKind::Door
                    && entity.locked
                    && door_matches_boundary(ship, entity, boundary)
            });
        let portal_type = match edge.kind {
            EdgeKind::Door => {
                if locked {
                    "LOCKED"
                } else {
                    "DOOR"
                }
            }
            EdgeKind::OpenCorridor => "HATCH",
            EdgeKind::Breach => "BREACH",
            EdgeKind::VerticalShaft => unreachable!(),
        };
        let Some(from_room) = room_ids.get(&edge.a) else {
            continue;
        };
        let Some(to_room) = room_ids.get(&edge.b) else {
            continue;
        };
        portals.push(PortalInfo {
            edge_key: boundary.edge_key.clone(),
            deck: boundary.deck,
            from_numeric: edge.a,
            to_numeric: edge.b,
            from_room: from_room.clone(),
            to_room: to_room.clone(),
            from_cell,
            to_cell,
            direction,
            portal_type,
            locked,
        });
    }
    portals.sort_by_key(|portal| (portal.deck, portal.edge_key.clone()));
    portals.dedup_by(|a, b| a.edge_key == b.edge_key);
    let portal_by_edge = portals
        .iter()
        .cloned()
        .map(|portal| (portal.edge_key.clone(), portal))
        .collect();

    let mut vertical_connections = Vec::new();
    for edge in &ship.room_graph.edges {
        if edge.kind != EdgeKind::VerticalShaft {
            continue;
        }
        let Some(connection) = find_vertical_connection(ship, edge.a, edge.b) else {
            continue;
        };
        vertical_connections.push(connection);
    }
    vertical_connections.sort_by_key(|connection| {
        (
            connection.from_deck,
            connection.from_numeric,
            connection.to_deck,
            connection.to_numeric,
        )
    });

    ExportContext {
        rooms,
        room_ids,
        occupancy,
        portals,
        portal_by_edge,
        vertical_connections,
    }
}

fn layout_value(ship: &Ship, kit_id: &str, context: &ExportContext) -> Value {
    let start_room = first_room_of_kind(context, RoomType::Airlock)
        .or_else(|| {
            context
                .rooms
                .values()
                .next()
                .map(|room| room.string_id.clone())
        })
        .unwrap_or_default();
    let goal_room = first_room_of_kind(context, RoomType::Engineering)
        .or_else(|| first_room_of_kind(context, RoomType::Bridge))
        .or_else(|| first_room_of_kind(context, RoomType::Reactor))
        .or_else(|| {
            context
                .rooms
                .values()
                .last()
                .map(|room| room.string_id.clone())
        })
        .unwrap_or_default();

    let portal_values: Vec<Value> = context.portals.iter().map(portal_value).collect();
    let rooms: Vec<Value> = context
        .rooms
        .values()
        .map(|room| room_value(room, context))
        .collect();
    let vertical_connections: Vec<Value> = context
        .vertical_connections
        .iter()
        .map(|connection| vertical_value(connection, context))
        .collect();
    let critical_path = critical_path_value(ship, context, &start_room, &goal_room);
    let structural_plan = structural_plan_value(ship, context);

    json!({
        "schema_version": "1.2.0",
        "cell_size": CELL_SIZE,
        "document_kind": "layout",
        "rooms": rooms,
        "portals": portal_values,
        "room_links": context.portals.iter().map(portal_value).collect::<Vec<_>>(),
        "structural_room_links": context.portals.iter().map(portal_value).collect::<Vec<_>>(),
        "vertical_connections": vertical_connections,
        "critical_path": critical_path,
        "structural_plan": structural_plan,
        "kit_id": kit_id,
        "encounters": [],
        "landmarks": [],
        "blocked_links": [],
        "adjacency_intents": [],
        "hazard_source": "runtime",
        "design_intent": {},
        "program_id": "worldgen_v2",
        "prototype": "worldgen",
        "seed_value": ship.seed,
        "archetype_id": ship.archetype_id,
        "structural_plan_validated": true,
    })
}

fn room_value(room: &RoomInfo, context: &ExportContext) -> Value {
    let cells: Vec<Value> = room
        .cells
        .iter()
        .map(|cell| json!(coord_string(*cell)))
        .collect();
    let (width, height) = room_footprint(room);
    let room_portals: Vec<Value> = context
        .portals
        .iter()
        .filter(|portal| {
            portal.from_numeric == room.numeric_id || portal.to_numeric == room.numeric_id
        })
        .map(portal_value)
        .collect();
    let reserved: BTreeSet<(i32, i32)> = context
        .portals
        .iter()
        .filter_map(|portal| {
            if portal.from_numeric == room.numeric_id {
                Some(portal.from_cell)
            } else if portal.to_numeric == room.numeric_id {
                Some(portal.to_cell)
            } else {
                None
            }
        })
        .collect();
    let mut center_slots = Vec::new();
    let mut wall_slots = Vec::new();
    for cell in &room.cells {
        let is_wall_adjacent = [(0, -1), (0, 1), (-1, 0), (1, 0)].iter().any(|(dx, dy)| {
            context
                .occupancy
                .get(&(room.deck, cell.0 + dx, cell.1 + dy))
                .map(|other| *other != room.numeric_id)
                .unwrap_or(true)
        });
        if reserved.contains(cell) {
            continue;
        }
        if is_wall_adjacent {
            wall_slots.push(json!(coord_string(*cell)));
        } else {
            center_slots.push(json!(coord_string(*cell)));
        }
    }

    json!({
        "id": room.string_id,
        "deck": room.deck,
        "cells": cells,
        "footprint": format!("({}, {})", width, height),
        "role": room_role(room.kind),
        "room_role": room_role(room.kind),
        "portals": room_portals,
        "interior_zones": {
            "center_slots": center_slots,
            "reserved_cells": reserved.iter().map(|cell| json!(coord_string(*cell))).collect::<Vec<_>>(),
            "wall_slots": wall_slots,
        },
        "variant": "standard",
    })
}

fn structural_plan_value(ship: &Ship, context: &ExportContext) -> Value {
    let mut occupancy = Map::new();
    let mut floor_placements = Vec::new();
    let mut ceiling_placements = Vec::new();
    let mut edge_map = BTreeMap::new();
    let mut placements = Vec::new();
    let mut vertical_openings = BTreeSet::new();
    for connection in &context.vertical_connections {
        vertical_openings.insert((connection.from_deck, connection.from_cell));
        vertical_openings.insert((connection.to_deck, connection.to_cell));
    }

    for ((deck, x, y), numeric_room_id) in &context.occupancy {
        let Some(room_id) = context.room_ids.get(numeric_room_id) else {
            continue;
        };
        let key = cell_key(*deck, *x, *y);
        let position = cell_position(*deck, *x, *y);
        occupancy.insert(
            key.clone(),
            json!({
                "cell_key": key,
                "deck": deck,
                "cell": [x, y],
                "room_id": room_id,
                "room_ids": [room_id],
                "position": position,
                "module_id": "floor_1x1",
            }),
        );
        floor_placements.push(json!({
            "id": format!("floor:{}", key),
            "placement_id": format!("floor:{}", key),
            "module_id": "floor_1x1",
            "position": position,
            "yaw_degrees": 0.0,
            "deck": deck,
            "cell": [x, y],
            "cell_key": key,
            "room_id": room_id,
            "room_ids": [room_id],
        }));
        if !vertical_openings.contains(&(*deck, (*x, *y))) {
            ceiling_placements.push(json!({
                "id": format!("ceiling:{}", key),
                "placement_id": format!("ceiling:{}", key),
                "module_id": "ceiling_cap_1x1",
                "position": position,
                "yaw_degrees": 0.0,
                "deck": deck,
                "cell": [x, y],
                "cell_key": key,
                "room_id": room_id,
                "room_ids": [room_id],
            }));
        }
    }

    let directions = [
        ("north", (0, -1)),
        ("east", (1, 0)),
        ("south", (0, 1)),
        ("west", (-1, 0)),
    ];
    for ((deck, x, y), numeric_room_id) in &context.occupancy {
        let layer = &ship.decks[*deck as usize].layer;
        for (direction, (dx, dy)) in directions {
            let edge_key = edge_key(*deck, *x, *y, direction);
            if edge_map.contains_key(&edge_key) {
                continue;
            }
            let other_numeric = context.occupancy.get(&(*deck, *x + dx, *y + dy)).copied();
            let wall = layer.edge(*x, *y, side_for_direction(direction));
            let portal = context.portal_by_edge.get(&edge_key);
            let (kind, module_id, portal_present) = if let Some(portal) = portal {
                (
                    portal.portal_type,
                    module_for_kind(portal.portal_type),
                    true,
                )
            } else if other_numeric == Some(*numeric_room_id) {
                ("OPEN", "", false)
            } else if wall == WallEdge::Breached {
                ("BREACH", "wall_straight_1x1", false)
            } else if wall == WallEdge::Doorway {
                let kind = if door_locked_on_edge(ship, *deck, &edge_key) {
                    "LOCKED"
                } else {
                    "DOOR"
                };
                (kind, module_for_kind(kind), true)
            } else {
                ("SOLID", "wall_straight_1x1", false)
            };
            let owner_room = context
                .room_ids
                .get(numeric_room_id)
                .cloned()
                .unwrap_or_default();
            let other_room = other_numeric
                .and_then(|id| context.room_ids.get(&id).cloned())
                .unwrap_or_default();
            let source_cells = vec![json!([x, y, deck]), json!([*x + dx, *y + dy, deck])];
            let record = json!({
                "id": format!("edge:{}", edge_key),
                "key": edge_key,
                "edge_key": edge_key,
                "deck": deck,
                "cell": [x, y],
                "direction": direction,
                "opposite_direction": opposite_direction(direction),
                "source_cells": source_cells,
                "room_ids": [owner_room, other_room],
                "owner_room": owner_room,
                "other_room": other_room,
                "kind": kind,
                "state": kind,
                "module_id": module_id,
                "position": edge_position(*deck, *x, *y, direction),
                "yaw_degrees": yaw_for_direction(direction),
                "portal": portal_present,
                "exterior": other_numeric.is_none(),
                "placement_required": kind != "OPEN",
                "wrapper_required": kind != "OPEN",
            });
            edge_map.insert(edge_key.clone(), record.clone());
            if kind != "OPEN" {
                let mut placement = record;
                if let Some(object) = placement.as_object_mut() {
                    object.insert(
                        "placement_id".to_string(),
                        json!(format!("edge:{}", edge_key)),
                    );
                }
                placements.push(placement);
            }
        }
    }

    let edges: Map<String, Value> = edge_map.into_iter().collect();

    // Generate socket bindings from adjacent floor placements.
    let mut socket_bindings = Vec::new();
    let floor_keys: Vec<&String> = occupancy.keys().collect();
    for key in &floor_keys {
        // Parse cell_key "deck|x|y"
        let parts: Vec<&str> = key.split('|').collect();
        if parts.len() != 3 { continue; }
        let (Ok(dk), Ok(cx), Ok(cy)) = (parts[0].parse::<u8>(), parts[1].parse::<i32>(), parts[2].parse::<i32>()) else { continue; };
        for (dx, dy, socket_dir) in [(1i32, 0i32, "east"), (0, 1, "south")] {
            let neighbor_key = cell_key(dk, cx + dx, cy + dy);
            if occupancy.contains_key(&neighbor_key) {
                socket_bindings.push(json!({
                    "placement_id": format!("floor:{}", key),
                    "socket_id": socket_dir,
                    "neighbor_placement_id": format!("floor:{}", neighbor_key),
                    "neighbor_socket_id": if socket_dir == "east" { "west" } else { "north" },
                }));
            }
        }
    }

    json!({
        "placements": placements,
        "floor_placements": floor_placements,
        "ceiling_placements": ceiling_placements,
        "occupancy": occupancy,
        "edges": edges,
        "errors": [],
        "socket_bindings": socket_bindings,
    })
}

fn gameplay_slice_value(ship: &Ship, context: &ExportContext) -> Value {
    let start_room = first_room_of_kind(context, RoomType::Airlock)
        .or_else(|| {
            context
                .rooms
                .values()
                .next()
                .map(|room| room.string_id.clone())
        })
        .unwrap_or_default();
    let goal_room = first_room_of_kind(context, RoomType::Engineering)
        .or_else(|| first_room_of_kind(context, RoomType::Bridge))
        .or_else(|| first_room_of_kind(context, RoomType::Reactor))
        .or_else(|| {
            context
                .rooms
                .values()
                .last()
                .map(|room| room.string_id.clone())
        })
        .unwrap_or_default();

    let mut objectives = Vec::new();
    let mut sequence = 1;
    for room in context.rooms.values() {
        if room.string_id == start_room {
            continue;
        }
        let approach = room
            .cells
            .first()
            .map(|(x, y)| json!([x, y, room.deck]))
            .unwrap_or_else(|| json!([0, 0, room.deck]));
        let is_goal = room.string_id == goal_room;
        objectives.push(json!({
            "id": if is_goal { "obj_reach_goal".to_string() } else { format!("obj_salvage_{}", room.string_id) },
            "sequence": sequence,
            "type": if is_goal { "interact" } else { "salvage" },
            "kind": "single",
            "room_id": room.string_id,
            "approach_cell": approach,
        }));
        sequence += 1;
    }
    if objectives.is_empty() && !goal_room.is_empty() {
        let goal = context
            .rooms
            .values()
            .find(|room| room.string_id == goal_room);
        let approach = goal
            .and_then(|room| room.cells.first().map(|(x, y)| json!([x, y, room.deck])))
            .unwrap_or_else(|| json!([0, 0, 0]));
        objectives.push(json!({
            "id": "obj_reach_goal",
            "sequence": 1,
            "type": "interact",
            "kind": "single",
            "room_id": goal_room,
            "approach_cell": approach,
        }));
    }

    let mut loot_containers = Vec::new();
    for entity in &ship.entities {
        if entity.kind != EntityKind::Container {
            continue;
        }
        let room_numeric = context
            .occupancy
            .get(&(entity.pos.deck, entity.pos.x, entity.pos.y))
            .copied();
        let Some(room_numeric) = room_numeric else {
            continue;
        };
        let Some(room_id) = context.room_ids.get(&room_numeric) else {
            continue;
        };
        let items: Vec<Value> = entity
            .inventory
            .iter()
            .map(|stack| json!({ "item_id": stack.item_id, "qty": stack.qty }))
            .collect();
        loot_containers.push(json!({
            "id": format!("loot_{}", entity.id),
            "entity_id": entity.id,
            "kind": entity.proto,
            "room_id": room_id,
            "approach_cell": [entity.pos.x, entity.pos.y, entity.pos.deck],
            "items": items,
        }));
    }

    json!({
        "start_room": start_room,
        "goal_room": goal_room,
        "objectives": objectives,
        "loot_containers": loot_containers,
        "fire_zones": [],
        "breach_zones": [],
        "arc_zones": [],
    })
}

fn portal_value(portal: &PortalInfo) -> Value {
    json!({
        "id": format!("portal_{}_{}", portal.from_room, portal.to_room),
        "from_room": portal.from_room,
        "to_room": portal.to_room,
        "edge_key": portal.edge_key,
        "direction": portal.direction,
        "deck": portal.deck,
        "portal_type": portal.portal_type,
        "source_cells": [coord_string(portal.from_cell), coord_string(portal.to_cell)],
        "required": true,
        "from_cell": [portal.from_cell.0, portal.from_cell.1],
        "to_cell": [portal.to_cell.0, portal.to_cell.1],
        "from_direction": portal.direction,
        "to_direction": opposite_direction(portal.direction),
        "edge_cell": [portal.from_cell.0, portal.from_cell.1],
        "edge_direction": portal.direction,
        "state": portal.portal_type,
        "module_id": module_for_kind(portal.portal_type),
        "locked": portal.locked,
        "logical_boundary": false,
    })
}

fn vertical_value(connection: &VerticalInfo, context: &ExportContext) -> Value {
    let from_room = context
        .room_ids
        .get(&connection.from_numeric)
        .cloned()
        .unwrap_or_default();
    let to_room = context
        .room_ids
        .get(&connection.to_numeric)
        .cloned()
        .unwrap_or_default();
    json!({
        "from_room": from_room,
        "to_room": to_room,
        "from_deck": connection.from_deck,
        "to_deck": connection.to_deck,
        "from_cell": [connection.from_cell.0, connection.from_cell.1],
        "to_cell": [connection.to_cell.0, connection.to_cell.1],
        "type": "hatch",
        "module_id": "bulkhead_portal_2x1",
    })
}

fn critical_path_value(
    ship: &Ship,
    context: &ExportContext,
    start_room: &str,
    goal_room: &str,
) -> Vec<Value> {
    let start = context
        .rooms
        .values()
        .find(|room| room.string_id == start_room)
        .map(|room| room.numeric_id);
    let goal = context
        .rooms
        .values()
        .find(|room| room.string_id == goal_room)
        .map(|room| room.numeric_id);
    let (Some(start), Some(goal)) = (start, goal) else {
        return Vec::new();
    };
    let mut adjacency: BTreeMap<u16, Vec<u16>> = BTreeMap::new();
    for edge in &ship.room_graph.edges {
        adjacency.entry(edge.a).or_default().push(edge.b);
        adjacency.entry(edge.b).or_default().push(edge.a);
    }
    for neighbors in adjacency.values_mut() {
        neighbors.sort_unstable();
        neighbors.dedup();
    }
    let mut previous: BTreeMap<u16, u16> = BTreeMap::new();
    let mut queue = VecDeque::from([start]);
    previous.insert(start, start);
    while let Some(current) = queue.pop_front() {
        if current == goal {
            break;
        }
        for neighbor in adjacency.get(&current).into_iter().flatten() {
            if !previous.contains_key(neighbor) {
                previous.insert(*neighbor, current);
                queue.push_back(*neighbor);
            }
        }
    }
    if !previous.contains_key(&goal) {
        return Vec::new();
    }
    let mut path = vec![goal];
    let mut current = goal;
    while current != start {
        current = previous[&current];
        path.push(current);
    }
    path.reverse();
    path.windows(2)
        .filter_map(|pair| {
            let from = context.room_ids.get(&pair[0])?;
            let to = context.room_ids.get(&pair[1])?;
            Some(json!({ "from": from, "to": to }))
        })
        .collect()
}

fn find_vertical_connection(ship: &Ship, first: u16, second: u16) -> Option<VerticalInfo> {
    for (deck_index, deck) in ship
        .decks
        .iter()
        .enumerate()
        .take(ship.decks.len().saturating_sub(1))
    {
        let upper = &ship.decks[deck_index + 1].layer;
        for y in 0..deck.layer.height.min(upper.height) as i32 {
            for x in 0..deck.layer.width.min(upper.width) as i32 {
                let a = deck.layer.room_at(x, y);
                let b = upper.room_at(x, y);
                if ordered_pair(a, b) != ordered_pair(first, second) || a == NO_ROOM || b == NO_ROOM
                {
                    continue;
                }
                let (from_numeric, to_numeric, from_cell, to_cell, from_deck, to_deck) =
                    if a == first {
                        (
                            a,
                            b,
                            (x, y),
                            (x, y),
                            deck_index as u8,
                            (deck_index + 1) as u8,
                        )
                    } else {
                        (
                            b,
                            a,
                            (x, y),
                            (x, y),
                            (deck_index + 1) as u8,
                            deck_index as u8,
                        )
                    };
                return Some(VerticalInfo {
                    from_numeric,
                    to_numeric,
                    from_cell,
                    to_cell,
                    from_deck,
                    to_deck,
                });
            }
        }
    }
    None
}

fn door_locked_on_edge(ship: &Ship, deck: u8, edge_key: &str) -> bool {
    ship.entities.iter().any(|entity| {
        entity.kind == EntityKind::Door
            && entity.pos.deck == deck
            && entity.locked
            && entity_boundary(ship, entity)
                .map(|boundary| boundary.edge_key == edge_key)
                .unwrap_or(false)
    })
}

fn door_matches_boundary(
    ship: &Ship,
    entity: &derelict_core::model::EntitySpec,
    boundary: &Boundary,
) -> bool {
    let Some(door_boundary) = entity_boundary(ship, entity) else {
        return false;
    };
    door_boundary.edge_key == boundary.edge_key && door_boundary.deck == boundary.deck
}

fn entity_boundary(ship: &Ship, entity: &derelict_core::model::EntitySpec) -> Option<Boundary> {
    if entity.kind != EntityKind::Door || entity.pos.deck as usize >= ship.decks.len() {
        return None;
    }
    let (direction, neighbor, edge_key) = if entity.rotation == 0 {
        (
            "north",
            (entity.pos.x, entity.pos.y - 1),
            format!("{}|h|{}|{}", entity.pos.deck, entity.pos.y, entity.pos.x),
        )
    } else {
        (
            "west",
            (entity.pos.x - 1, entity.pos.y),
            format!("{}|v|{}|{}", entity.pos.deck, entity.pos.y, entity.pos.x),
        )
    };
    Some(Boundary {
        deck: entity.pos.deck,
        cell: (entity.pos.x, entity.pos.y),
        neighbor,
        direction,
        edge_key,
    })
}

impl Boundary {
    fn cell_room(&self, occupancy: &BTreeMap<(u8, i32, i32), u16>) -> Option<u16> {
        occupancy
            .get(&(self.deck, self.cell.0, self.cell.1))
            .copied()
    }
}

fn first_room_of_kind(context: &ExportContext, kind: RoomType) -> Option<String> {
    context
        .rooms
        .values()
        .find(|room| room.kind == kind)
        .map(|room| room.string_id.clone())
}

fn room_footprint(room: &RoomInfo) -> (i32, i32) {
    let min_x = room.cells.iter().map(|(x, _)| *x).min().unwrap_or(0);
    let max_x = room.cells.iter().map(|(x, _)| *x).max().unwrap_or(-1);
    let min_y = room.cells.iter().map(|(_, y)| *y).min().unwrap_or(0);
    let max_y = room.cells.iter().map(|(_, y)| *y).max().unwrap_or(-1);
    (max_x - min_x + 1, max_y - min_y + 1)
}

fn ordered_pair(a: u16, b: u16) -> (u16, u16) {
    if a <= b {
        (a, b)
    } else {
        (b, a)
    }
}

fn room_role(kind: RoomType) -> &'static str {
    match kind {
        RoomType::Bridge => "bridge",
        RoomType::Engineering => "engineering",
        RoomType::Reactor => "reactor",
        RoomType::CrewQuarters => "crew_quarters",
        RoomType::Cargo => "cargo",
        RoomType::Medbay => "medbay",
        RoomType::Galley => "galley",
        RoomType::Armory => "armory",
        RoomType::Storage => "storage",
        RoomType::Hydroponics => "hydroponics",
        RoomType::Airlock => "airlock",
        RoomType::Corridor => "corridor",
        RoomType::VerticalShaft => "vertical_shaft",
        RoomType::Compartment => "compartment",
    }
}

fn coord_string((x, y): (i32, i32)) -> String {
    format!("({}, {})", x, y)
}

fn cell_key(deck: u8, x: i32, y: i32) -> String {
    format!("{}|{}|{}", deck, x, y)
}

fn edge_key(deck: u8, x: i32, y: i32, direction: &str) -> String {
    // Must match StructuralEdgePlan.edge_key(): normalize to min(cell, neighbor).
    match direction {
        "north" => format!("{}|h|{}|{}", deck, y - 1, x),
        "south" => format!("{}|h|{}|{}", deck, y, x),
        "west" => format!("{}|v|{}|{}", deck, y, x - 1),
        "east" => format!("{}|v|{}|{}", deck, y, x),
        _ => String::new(),
    }
}

fn cell_position(deck: u8, x: i32, y: i32) -> Value {
    json!([
        x as i64 * CELL_SIZE,
        deck as i64 * DECK_HEIGHT,
        y as i64 * CELL_SIZE
    ])
}

fn edge_position(deck: u8, x: i32, y: i32, direction: &str) -> Value {
    let (dx, dy) = match direction {
        "north" => (0.0, -0.5),
        "east" => (0.5, 0.0),
        "south" => (0.0, 0.5),
        "west" => (-0.5, 0.0),
        _ => (0.0, 0.0),
    };
    json!([
        x as f64 * CELL_SIZE as f64 + dx * CELL_SIZE as f64,
        deck as f64 * DECK_HEIGHT as f64,
        y as f64 * CELL_SIZE as f64 + dy * CELL_SIZE as f64,
    ])
}

fn side_for_direction(direction: &str) -> Side {
    match direction {
        "north" => Side::North,
        "east" => Side::East,
        "south" => Side::South,
        "west" => Side::West,
        _ => Side::North,
    }
}

fn opposite_direction(direction: &str) -> &'static str {
    match direction {
        "north" => "south",
        "east" => "west",
        "south" => "north",
        "west" => "east",
        _ => "north",
    }
}

fn yaw_for_direction(direction: &str) -> f64 {
    match direction {
        "north" => 180.0,
        "east" => 270.0,
        "south" => 0.0,
        "west" => 90.0,
        _ => 0.0,
    }
}

fn module_for_kind(kind: &str) -> &'static str {
    match kind {
        "SOLID" | "BREACH" => "wall_straight_1x1",
        "DOOR" => "doorway_frame_open_1x1",
        "LOCKED" => "doorway_frame_blocked_1x1",
        "HATCH" => "bulkhead_portal_2x1",
        _ => "wall_straight_1x1",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use derelict_core::{GenData, GenParams};

    fn sample_ship() -> Ship {
        let data = GenData::default_bundle().expect("embedded generation data");
        let mut params = GenParams::new("shuttle");
        params.intactness_override = Some(9_500);
        derelict_core::generate_ship(42, &params, &data).expect("sample ship generation")
    }

    #[test]
    fn layout_export_has_required_json_contract() {
        let value: Value =
            serde_json::from_str(&ship_to_layout_json(&sample_ship(), "ship_structural_v0"))
                .expect("valid layout JSON");
        assert_eq!(value["schema_version"], "1.2.0");
        assert_eq!(value["document_kind"], "layout");
        assert_eq!(value["program_id"], "worldgen_v2");
        assert_eq!(value["kit_id"], "ship_structural_v0");
        assert!(value["rooms"]
            .as_array()
            .is_some_and(|rooms| !rooms.is_empty()));
        assert!(value["structural_plan"]["errors"]
            .as_array()
            .is_some_and(|errors| errors.is_empty()));
        let first_room = &value["rooms"][0];
        assert!(first_room["id"].is_string());
        assert!(first_room["cells"][0].is_string());
        assert!(first_room["footprint"].is_string());
    }

    #[test]
    fn gameplay_export_has_objectives_and_loot_shape() {
        let value: Value = serde_json::from_str(&ship_to_gameplay_slice_json(&sample_ship()))
            .expect("valid gameplay JSON");
        assert!(value["start_room"].is_string());
        assert!(value["goal_room"].is_string());
        assert!(value["objectives"]
            .as_array()
            .is_some_and(|items| !items.is_empty()));
        assert!(value["loot_containers"].is_array());
    }
}
