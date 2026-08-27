//! Structural compiler: authored topology (explicit room occupancy + portal
//! intents) → canonical `StructuralPlan`. Port of The Synaptic Sea's
//! `structural_edge_compiler.gd`.
//!
//! Rooms own explicit integer occupancy cells. Floors are emitted once per
//! occupied cell; walls and portals are emitted once per canonical shared
//! edge (`edge_key` dedup makes the second side a no-op). Module ids are
//! chosen through a `ModulePicker` (socket-catalog-driven in production;
//! constant defaults otherwise) — never hardcoded at emission sites.

use crate::structural::plan::*;
use std::collections::{BTreeMap, BTreeSet};

pub const FLOOR_MODULE: &str = "floor_1x1";
pub const CORRIDOR_FLOOR_MODULE: &str = "corridor_floor_1x1";
pub const CEILING_MODULE: &str = "ceiling_cap_1x1";
pub const WALL_MODULE: &str = "wall_straight_1x1";
pub const DOOR_MODULE: &str = "doorway_frame_open_1x1";
pub const LOCKED_MODULE: &str = "doorway_frame_blocked_1x1";
pub const HATCH_MODULE: &str = "bulkhead_portal_2x1";
pub const INNER_CORNER_MODULE: &str = "wall_inner_corner";
pub const OUTER_CORNER_MODULE: &str = "wall_outer_corner";
pub const T_JUNCTION_MODULE: &str = "wall_t_junction";

/// Module selection strategy. The default picker returns the kit's standard
/// module ids; the socket-catalog picker (structural::sockets) verifies
/// socket-kind requirements against real contract data.
pub trait ModulePicker {
    fn floor(&self, role_is_connective: bool) -> String;
    fn ceiling(&self) -> String;
    fn wall(&self) -> String;
    fn portal(&self, state: EdgeKind) -> String;
    fn vertex(&self, kind: VertexKind) -> Option<String>;
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum VertexKind {
    InnerCorner,
    OuterCorner,
    TJunction,
}

#[derive(Default)]
pub struct DefaultModulePicker;

impl ModulePicker for DefaultModulePicker {
    fn floor(&self, role_is_connective: bool) -> String {
        if role_is_connective {
            CORRIDOR_FLOOR_MODULE.into()
        } else {
            FLOOR_MODULE.into()
        }
    }
    fn ceiling(&self) -> String {
        CEILING_MODULE.into()
    }
    fn wall(&self) -> String {
        WALL_MODULE.into()
    }
    fn portal(&self, state: EdgeKind) -> String {
        match state {
            EdgeKind::Locked => LOCKED_MODULE.into(),
            EdgeKind::Hatch => HATCH_MODULE.into(),
            EdgeKind::Breach => String::new(),
            _ => DOOR_MODULE.into(),
        }
    }
    fn vertex(&self, kind: VertexKind) -> Option<String> {
        Some(match kind {
            VertexKind::InnerCorner => INNER_CORNER_MODULE.into(),
            VertexKind::OuterCorner => OUTER_CORNER_MODULE.into(),
            VertexKind::TJunction => T_JUNCTION_MODULE.into(),
        })
    }
}

pub fn compile(topology: &Topology, picker: &dyn ModulePicker) -> StructuralPlan {
    let mut plan = StructuralPlan::default();
    let mut room_by_cell: BTreeMap<String, RoomId> = BTreeMap::new();
    let mut role_of: BTreeMap<RoomId, crate::role::Role> = BTreeMap::new();
    let mut deck_of: BTreeMap<RoomId, u8> = BTreeMap::new();

    // --- 1. Occupancy ------------------------------------------------------
    for room in &topology.rooms {
        if room.id == NO_ROOM {
            plan.errors.push("room uses reserved id 0".into());
            continue;
        }
        if role_of.insert(room.id, room.role).is_some() {
            plan.errors.push(format!("duplicate room id {}", room.id));
            continue;
        }
        deck_of.insert(room.id, room.deck);
        for &cell in &room.cells {
            if cell.deck != room.deck {
                plan.errors.push(format!(
                    "room {} declares cell {} on wrong deck (room deck {})",
                    room.id,
                    cell.key(),
                    room.deck
                ));
                continue;
            }
            let key = cell.key();
            if let Some(prev) = room_by_cell.insert(key.clone(), room.id) {
                plan.errors.push(format!(
                    "occupied-cell overlap: {key} owned by {prev} and {}",
                    room.id
                ));
                continue;
            }
            plan.occupancy.insert(
                key,
                CellRecord {
                    cell,
                    room_id: room.id,
                    module_id: picker.floor(room.role.is_connective()),
                    decal: 0,
                    variant: DamageVariant::Intact,
                },
            );
        }
    }

    // --- 2. Index portals by canonical edge key ----------------------------
    let mut portal_by_edge: BTreeMap<String, &PortalIntent> = BTreeMap::new();
    for portal in &topology.portals {
        if portal.from_room == portal.to_room {
            plan.errors.push(format!(
                "portal connects room {} to itself",
                portal.from_room
            ));
            continue;
        }
        if portal.from_cell.deck != portal.to_cell.deck {
            plan.errors
                .push("cross-deck portal must remain a vertical connection".into());
            continue;
        }
        // Endpoint ownership: cells must belong to the declared rooms.
        let from_owner = room_by_cell.get(&portal.from_cell.key()).copied();
        if from_owner != Some(portal.from_room) {
            plan.errors.push(format!(
                "portal endpoints are not owned by declared rooms ({} -> {})",
                portal.from_room, portal.to_room
            ));
            continue;
        }
        if portal.exterior || portal.to_room == NO_ROOM {
            // Exterior door: to_cell is void space just outside the hull.
            if room_by_cell.contains_key(&portal.to_cell.key()) {
                plan.errors.push(format!(
                    "exterior portal target cell {} is occupied",
                    portal.to_cell.key()
                ));
                continue;
            }
        } else {
            let to_owner = room_by_cell.get(&portal.to_cell.key()).copied();
            if to_owner != Some(portal.to_room) {
                plan.errors.push(format!(
                    "portal endpoints are not owned by declared rooms ({} -> {})",
                    portal.from_room, portal.to_room
                ));
                continue;
            }
        }
        let Some(dir) = Dir::between(portal.from_cell, portal.to_cell) else {
            plan.errors.push(format!(
                "portal endpoints are not adjacent ({} -> {})",
                portal.from_cell.key(),
                portal.to_cell.key()
            ));
            continue;
        };
        let key = edge_key(portal.from_cell, dir);
        if portal_by_edge.insert(key.clone(), portal).is_some() {
            plan.errors.push(format!("duplicate portal edge: {key}"));
        }
    }

    // --- 3. Vertical opening cells (no ceilings there) ---------------------
    let mut vertical_openings: BTreeSet<String> = BTreeSet::new();
    for v in &topology.verticals {
        vertical_openings.insert(v.from_cell.key());
        vertical_openings.insert(v.to_cell.key());
    }

    // --- 4. Per-cell pass: floors, ceilings, canonical edges ---------------
    // BTreeMap iteration = deterministic order.
    let cells: Vec<CellRecord> = plan.occupancy.values().cloned().collect();
    for rec in &cells {
        let cell_key_s = rec.cell.key();
        plan.floor_placements.push(FloorPlacement {
            id: format!("floor:{cell_key_s}"),
            cell: rec.cell,
            cell_key: cell_key_s.clone(),
            room_id: rec.room_id,
            module_id: rec.module_id.clone(),
            position: rec.cell.world_pos(),
            yaw_degrees: 0,
            variant: DamageVariant::Intact,
        });
        if !vertical_openings.contains(&cell_key_s) {
            plan.ceiling_placements.push(FloorPlacement {
                id: format!("ceiling:{cell_key_s}"),
                cell: rec.cell,
                cell_key: cell_key_s.clone(),
                room_id: rec.room_id,
                module_id: picker.ceiling(),
                position: rec.cell.world_pos(),
                yaw_degrees: 0,
                variant: DamageVariant::Intact,
            });
        }

        for dir in Dir::ALL {
            let key = edge_key(rec.cell, dir);
            if plan.edges.contains_key(&key) {
                continue; // canonical dedup: second side is a no-op
            }
            let neighbor = rec.cell.neighbor(dir);
            let other_room = room_by_cell
                .get(&neighbor.key())
                .copied()
                .unwrap_or(NO_ROOM);
            let portal = portal_by_edge.get(&key).copied();

            let (kind, module_id, is_portal, exterior) = match portal {
                Some(p) => {
                    let exterior = p.exterior || p.to_room == NO_ROOM;
                    if other_room == NO_ROOM && !exterior {
                        plan.errors.push(format!(
                            "portal endpoint is exterior without explicit exterior flag: {key}"
                        ));
                    }
                    (p.state, picker.portal(p.state), true, exterior)
                }
                None if other_room == rec.room_id => (EdgeKind::Open, String::new(), false, false),
                None => (EdgeKind::Solid, picker.wall(), false, other_room == NO_ROOM),
            };
            let wrapper_required = kind != EdgeKind::Open && !module_id.is_empty();
            plan.edges.insert(
                key.clone(),
                EdgeRecord {
                    edge_key: key,
                    kind,
                    module_id,
                    variant: DamageVariant::Intact,
                    position: edge_world_position(rec.cell, dir),
                    yaw_degrees: dir.yaw_degrees(),
                    cell: rec.cell,
                    direction: dir,
                    room_ids: (rec.room_id, other_room),
                    source_cells: [rec.cell, neighbor],
                    portal: is_portal,
                    exterior,
                    wrapper_required: false, // set uniformly below
                },
            );
            let _ = wrapper_required; // stored below via recompute (kept in one place)
        }
    }
    // wrapper_required is derivable; store it explicitly for the contract.
    for edge in plan.edges.values_mut() {
        edge_set_wrapper_required(edge);
    }

    // Vertex modules are vertex-centered compound assets. They cannot safely
    // replace an edge-centered wall record without a separate vertex placement
    // position and orientation contract. Keep canonical SOLID edge placements
    // as straight walls until that explicit vertex-placement IR exists.

    // --- 5. Materialize placements (sorted by edge_key via BTreeMap) --------
    plan.placements = plan
        .edges
        .values()
        .filter(|e| e.kind != EdgeKind::Open && wrapper_required(e))
        .cloned()
        .collect();

    // --- 6. Socket bindings (geometric adjacency) ---------------------------
    emit_socket_bindings(&mut plan);

    plan
}

fn wrapper_required(e: &EdgeRecord) -> bool {
    e.wrapper_required
}

pub(crate) fn edge_set_wrapper_required(e: &mut EdgeRecord) {
    e.wrapper_required = e.kind != EdgeKind::Open && !e.module_id.is_empty();
}

/// Geometric socket bindings: every floor binds to its adjacent materialized
/// edges (both directions recorded), matching the game's floor_edge ↔
/// wall_base contract without needing per-contract position data. (The
/// socket catalog layer validates real socket compatibility when loaded.)
pub(crate) fn emit_socket_bindings(plan: &mut StructuralPlan) {
    let placed_edges: BTreeMap<String, String> = plan
        .placements
        .iter()
        .map(|e| (e.edge_key.clone(), format!("edge:{}", e.edge_key)))
        .collect();
    let mut bindings = Vec::new();
    for floor in &plan.floor_placements {
        let floor_pid = &floor.id;
        for dir in Dir::ALL {
            let key = edge_key(floor.cell, dir);
            if let Some(edge_pid) = placed_edges.get(&key) {
                bindings.push(SocketBinding {
                    placement_id: floor_pid.clone(),
                    socket_id: format!("floor_edge_{}_01", dir.name()),
                    neighbor_placement_id: edge_pid.clone(),
                    neighbor_socket_id: "wall_base_01".into(),
                    kind: "floor_edge".into(),
                });
                bindings.push(SocketBinding {
                    placement_id: edge_pid.clone(),
                    socket_id: "wall_base_01".into(),
                    neighbor_placement_id: floor_pid.clone(),
                    neighbor_socket_id: format!("floor_edge_{}_01", dir.name()),
                    kind: "wall_base".into(),
                });
            }
        }
    }
    plan.socket_bindings = bindings;
}
