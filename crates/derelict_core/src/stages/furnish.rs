//! Stage: furnishing on the structural plan — door entities from portal
//! edges (with lock rolls written BACK into the plan so exports agree),
//! interior zone slots per room, and slot-constrained furniture/container
//! placement. No entity can ever land on an unvalidated cell: placement
//! draws exclusively from the computed slot lists.

use crate::archetype::{FurnishingRules, Placement};
use crate::model::{EntityKind, EntitySpec, GridPos};
use crate::rng::{self, roll_bp, roll_range, shuffle};
use crate::role::Role;
use crate::structural::compile::{DefaultModulePicker, ModulePicker};
use crate::structural::plan::{Cell, Dir, EdgeKind, RoomId, StructuralPlan, Topology, NO_ROOM};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Interior slot classification for one room, exported per room in the game
/// contract (`interior_zones`) and used for all entity placement.
#[derive(Clone, PartialEq, Debug, Default, Serialize, Deserialize)]
pub struct InteriorZones {
    /// Cells kept clear: doorway-adjacent cells and vertical openings.
    pub reserved_cells: Vec<Cell>,
    /// Cells with at least one SOLID wall edge (and not reserved).
    pub wall_slots: Vec<Cell>,
    /// Cells with no wall edge (and not reserved).
    pub center_slots: Vec<Cell>,
}

/// Compute interior zones for every room from the compiled plan.
pub fn interior_zones(
    topology: &Topology,
    plan: &StructuralPlan,
) -> BTreeMap<RoomId, InteriorZones> {
    let mut vertical_cells: BTreeSet<String> = BTreeSet::new();
    for v in &topology.verticals {
        vertical_cells.insert(v.from_cell.key());
        vertical_cells.insert(v.to_cell.key());
    }
    let mut out: BTreeMap<RoomId, InteriorZones> = BTreeMap::new();
    for room in &topology.rooms {
        let mut zones = InteriorZones::default();
        for &cell in &room.cells {
            let mut has_wall = false;
            let mut has_door = false;
            for dir in Dir::ALL {
                let key = crate::structural::plan::edge_key(cell, dir);
                if let Some(edge) = plan.edges.get(&key) {
                    match edge.kind {
                        EdgeKind::Solid => has_wall = true,
                        EdgeKind::Door | EdgeKind::Locked | EdgeKind::Hatch => has_door = true,
                        _ => {}
                    }
                }
            }
            if has_door || vertical_cells.contains(&cell.key()) {
                zones.reserved_cells.push(cell);
            } else if has_wall {
                zones.wall_slots.push(cell);
            } else {
                zones.center_slots.push(cell);
            }
        }
        out.insert(room.id, zones);
    }
    out
}

pub struct FurnishOutcome {
    pub entities: Vec<EntitySpec>,
    pub zones: BTreeMap<RoomId, InteriorZones>,
    pub next_entity_id: u32,
}

/// Door and ladder entities implied by compiled portal edges and verticals.
/// No lock rolls and no plan mutation — the golden export path.
pub fn implied_access_entities(
    topology: &Topology,
    plan: &StructuralPlan,
    mut next_entity_id: u32,
) -> (Vec<EntitySpec>, u32) {
    let mut entities: Vec<EntitySpec> = Vec::new();
    let portal_keys: Vec<String> = plan
        .edges
        .iter()
        .filter(|(_, e)| e.portal)
        .map(|(k, _)| k.clone())
        .collect();
    for key in portal_keys {
        let e = &plan.edges[&key];
        let (pos, rotation) = door_pos_rotation(e.cell, e.direction);
        entities.push(EntitySpec {
            id: next_entity_id,
            kind: EntityKind::Door,
            proto: if e.exterior {
                "airlock_door".into()
            } else {
                "door".into()
            },
            pos,
            rotation,
            locked: false,
            open: false,
            inventory: Vec::new(),
            tags: vec![format!("edge:{key}")],
        });
        next_entity_id += 1;
    }
    for (vi, v) in topology.verticals.iter().enumerate() {
        for cell in [v.from_cell, v.to_cell] {
            entities.push(EntitySpec {
                id: next_entity_id,
                kind: EntityKind::Furniture,
                proto: "ladder".into(),
                pos: GridPos::new(cell.x, cell.y, cell.deck),
                rotation: 0,
                locked: false,
                open: false,
                inventory: Vec::new(),
                tags: vec![format!("shaft_{vi}")],
            });
            next_entity_id += 1;
        }
    }
    (entities, next_entity_id)
}

fn door_pos_rotation(cell: Cell, direction: Dir) -> (GridPos, u8) {
    // 2D-addon convention: doors sit on the north (rot 0) or west (rot 1)
    // edge of their tile; canonical east/south edges convert.
    match direction {
        Dir::North => (GridPos::new(cell.x, cell.y, cell.deck), 0),
        Dir::West => (GridPos::new(cell.x, cell.y, cell.deck), 1),
        Dir::South => (GridPos::new(cell.x, cell.y + 1, cell.deck), 0),
        Dir::East => (GridPos::new(cell.x + 1, cell.y, cell.deck), 1),
    }
}

/// Create door entities (from portal edges), roll locks (written back into
/// the plan as `Locked` edge kinds), and place furniture per room rules.
/// `skip_cells` are occupancy cells that already hold an AuthoredProp.
pub fn furnish(
    master_seed: u64,
    topology: &Topology,
    plan: &mut StructuralPlan,
    rules: &FurnishingRules,
    skip_cells: &BTreeSet<(u8, i32, i32)>,
) -> FurnishOutcome {
    let role_of: BTreeMap<RoomId, Role> = topology.rooms.iter().map(|r| (r.id, r.role)).collect();
    let mut entities: Vec<EntitySpec> = Vec::new();
    let mut next_entity_id: u32 = 1;
    let picker = DefaultModulePicker;

    // --- Doors: one entity per portal edge (BTreeMap order = stable ids) ---
    let portal_keys: Vec<String> = plan
        .edges
        .iter()
        .filter(|(_, e)| e.portal)
        .map(|(k, _)| k.clone())
        .collect();
    for key in portal_keys {
        let (cell, direction, exterior, rooms) = {
            let e = &plan.edges[&key];
            (e.cell, e.direction, e.exterior, e.room_ids)
        };
        let mut rng = rng::stream(master_seed, "door", next_entity_id as u64);
        let lock_bp = [rooms.0, rooms.1]
            .iter()
            .filter(|id| **id != NO_ROOM)
            .filter_map(|id| role_of.get(id))
            .filter_map(|role| rules.door_lock_bp.get(role).copied())
            .max()
            .unwrap_or(0);
        let locked = !exterior && roll_bp(&mut rng, lock_bp as u32);
        let open = !locked && roll_bp(&mut rng, 2500);
        if locked {
            let e = plan.edges.get_mut(&key).unwrap();
            e.kind = EdgeKind::Locked;
            e.module_id = picker.portal(EdgeKind::Locked);
        }
        // 2D-addon convention: doors sit on the north (rot 0) or west (rot 1)
        // edge of their tile; canonical east/south edges convert.
        let (pos, rotation) = match direction {
            Dir::North => (GridPos::new(cell.x, cell.y, cell.deck), 0),
            Dir::West => (GridPos::new(cell.x, cell.y, cell.deck), 1),
            Dir::South => (GridPos::new(cell.x, cell.y + 1, cell.deck), 0),
            Dir::East => (GridPos::new(cell.x + 1, cell.y, cell.deck), 1),
        };
        entities.push(EntitySpec {
            id: next_entity_id,
            kind: EntityKind::Door,
            proto: if exterior {
                "airlock_door".into()
            } else {
                "door".into()
            },
            pos,
            rotation,
            locked,
            open,
            inventory: Vec::new(),
            tags: vec![format!("edge:{key}")],
        });
        next_entity_id += 1;
    }

    // --- Ladder entities on vertical connections ----------------------------
    for (vi, v) in topology.verticals.iter().enumerate() {
        for cell in [v.from_cell, v.to_cell] {
            entities.push(EntitySpec {
                id: next_entity_id,
                kind: EntityKind::Furniture,
                proto: "ladder".into(),
                pos: GridPos::new(cell.x, cell.y, cell.deck),
                rotation: 0,
                locked: false,
                open: false,
                inventory: Vec::new(),
                tags: vec![format!("shaft_{vi}")],
            });
            next_entity_id += 1;
        }
    }

    // --- Furniture / containers per room, slot-constrained ------------------
    let zones = interior_zones(topology, plan);
    let mut occupied: BTreeSet<(u8, i32, i32)> = entities
        .iter()
        .map(|e| (e.pos.deck, e.pos.x, e.pos.y))
        .collect();
    occupied.extend(skip_cells.iter().copied());
    for room in &topology.rooms {
        let Some(rule_list) = rules.rules.get(&room.role) else {
            continue;
        };
        let Some(z) = zones.get(&room.id) else {
            continue;
        };
        let mut rng = rng::stream(master_seed, "furnish", room.id as u64);
        for rule in rule_list {
            let count = roll_range(&mut rng, rule.count.0 as i64, rule.count.1 as i64);
            if count == 0 {
                continue;
            }
            let mut candidates: Vec<Cell> = match rule.place {
                Placement::WallAdjacent | Placement::Corner => z.wall_slots.clone(),
                Placement::Center => z.center_slots.clone(),
                Placement::Free => {
                    let mut all = z.wall_slots.clone();
                    all.extend(z.center_slots.iter().copied());
                    all
                }
            };
            // Small rooms without center slots fall back to wall slots
            // (never to reserved cells).
            if candidates.is_empty() && rule.place == Placement::Center {
                candidates = z.wall_slots.clone();
            }
            shuffle(&mut rng, &mut candidates);
            let mut placed = 0;
            for cell in candidates {
                if placed >= count {
                    break;
                }
                if !occupied.insert((cell.deck, cell.x, cell.y)) {
                    continue;
                }
                let locked =
                    rule.kind == EntityKind::Container && roll_bp(&mut rng, rule.lock_bp as u32);
                entities.push(EntitySpec {
                    id: next_entity_id,
                    kind: rule.kind,
                    proto: rule.proto.clone(),
                    pos: GridPos::new(cell.x, cell.y, cell.deck),
                    rotation: roll_range(&mut rng, 0, 3) as u8,
                    locked,
                    open: false,
                    inventory: Vec::new(),
                    tags: Vec::new(),
                });
                next_entity_id += 1;
                placed += 1;
            }
        }
    }

    FurnishOutcome {
        entities,
        zones,
        next_entity_id,
    }
}
