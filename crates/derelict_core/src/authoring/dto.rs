//! Golden-area file schema. Compact cells and Role/EdgeKind names; adapter to Topology.

use crate::model::EntityKind;
use crate::role::Role;
use crate::structural::plan::{
    Cell, Dir, EdgeKind, PortalIntent, RoomId, RoomSpec, Topology, VerticalConnection, CELL_SIZE_M,
    DECK_HEIGHT_M,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GoldenScope {
    Room,
    Area,
    Derelict,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GoldenArea {
    pub schema_version: String,
    pub document_kind: String,
    pub id: String,
    pub display_name: String,
    pub scope: GoldenScope,
    pub kit_id: String,
    pub cell_size_m: f32,
    pub deck_height_m: f32,
    pub entry_room: String,
    pub goal_room: String,
    pub topology: TopologyDto,
    pub module_overrides: ModuleOverrides,
    pub props: Vec<AuthoredProp>,
    pub room_vars: BTreeMap<String, RoomVars>,
    pub hazards: AuthoredHazards,
    pub stamp: Option<StampMeta>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TopologyDto {
    pub rooms: Vec<RoomSpecDto>,
    pub portals: Vec<PortalIntentDto>,
    pub verticals: Vec<VerticalConnectionDto>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoomSpecDto {
    pub id: u16,
    pub stable_id: String,
    pub role: String,
    pub deck: u8,
    pub cells: Vec<[i32; 2]>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PortalIntentDto {
    pub from_room: u16,
    pub to_room: u16,
    pub from_cell: [i32; 3],
    pub to_cell: [i32; 3],
    pub state: String,
    pub exterior: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VerticalConnectionDto {
    pub from_room: u16,
    pub to_room: u16,
    pub from_cell: [i32; 3],
    pub to_cell: [i32; 3],
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModuleOverrides {
    pub floors: BTreeMap<String, String>,
    pub ceilings: BTreeMap<String, String>,
    pub edges: BTreeMap<String, String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RoomVars {
    pub oxygen_bp: u16,
    pub depressurized: bool,
    pub vented: bool,
    pub radiation_bp: u16,
    pub temperature_c: i16,
    pub notes: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoredProp {
    pub id: u32,
    pub kind: EntityKind,
    pub proto: String,
    pub visual_id: String,
    pub cell: [i32; 3],
    pub rotation: u8,
    pub facing: Option<String>,
    pub locked: bool,
    pub inventory_mode: InventoryMode,
    pub inventory: Vec<AuthoredStack>,
    pub loot_table: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InventoryMode {
    Explicit,
    LootTable,
    Empty,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoredStack {
    pub item_id: String,
    pub qty: u16,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthoredHazards {
    pub source: String,
    pub fire_zones: Vec<LinkZone>,
    pub breach_zones: Vec<LinkZone>,
    pub arc_zones: Vec<LinkZone>,
    pub radiation_zones: Vec<LinkZone>,
}

/// Loader-compatible overlay: from_cell/to_cell plus from_room/to_room.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct LinkZone {
    pub id: String,
    pub from_room: String,
    pub to_room: String,
    pub from_cell: [i32; 3],
    pub to_cell: [i32; 3],
    #[serde(default)]
    pub module_id: String,
    pub kind: String,
    #[serde(default)]
    pub compartment_id: String,
    #[serde(default)]
    pub rationale: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct StampMeta {
    pub compatible_roles: Vec<String>,
    pub attach_edges: Vec<AttachEdge>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachEdge {
    pub cell: [i32; 3],
    pub dir: String,
}

/// PortalIntent states only. SOLID/OPEN and anything else are compiled kinds.
fn parse_portal_state(state: &str) -> Result<EdgeKind, String> {
    match state {
        "DOOR" => Ok(EdgeKind::Door),
        "LOCKED" => Ok(EdgeKind::Locked),
        "HATCH" => Ok(EdgeKind::Hatch),
        "BREACH" => Ok(EdgeKind::Breach),
        other => Err(format!("invalid portal state '{other}'")),
    }
}

fn cell_from_xy(xy: [i32; 2], deck: u8) -> Cell {
    Cell::new(deck, xy[0], xy[1])
}

fn cell_from_xyz(xyz: [i32; 3]) -> Result<Cell, String> {
    let [x, y, deck] = xyz;
    let deck = u8::try_from(deck).map_err(|_| format!("deck {deck} out of range"))?;
    Ok(Cell::new(deck, x, y))
}

fn cell_to_xyz(cell: Cell) -> [i32; 3] {
    [cell.x, cell.y, i32::from(cell.deck)]
}

fn hazard_cell(xyz: [i32; 3], bucket: &str, id: &str) -> Result<Cell, String> {
    let [x, y, deck] = xyz;
    let deck = u8::try_from(deck)
        .map_err(|_| format!("{bucket} zone '{id}' has invalid cell deck {deck}"))?;
    Ok(Cell::new(deck, x, y))
}

impl TopologyDto {
    /// Compiler Topology from compact DTO rooms/portals/verticals.
    pub fn to_topology(&self) -> Result<Topology, String> {
        let mut seen_stable = BTreeSet::new();
        let mut rooms = Vec::with_capacity(self.rooms.len());
        for room in &self.rooms {
            if room.stable_id.is_empty() {
                return Err(format!("room {} has empty stable_id", room.id));
            }
            if !seen_stable.insert(room.stable_id.as_str()) {
                return Err(format!("duplicate stable_id '{}'", room.stable_id));
            }
            let role =
                Role::parse(&room.role).ok_or_else(|| format!("unknown role '{}'", room.role))?;
            rooms.push(RoomSpec {
                id: room.id,
                role,
                deck: room.deck,
                cells: room
                    .cells
                    .iter()
                    .copied()
                    .map(|xy| cell_from_xy(xy, room.deck))
                    .collect(),
            });
        }

        let mut portals = Vec::with_capacity(self.portals.len());
        for portal in &self.portals {
            portals.push(PortalIntent {
                from_room: portal.from_room,
                to_room: portal.to_room,
                from_cell: cell_from_xyz(portal.from_cell)?,
                to_cell: cell_from_xyz(portal.to_cell)?,
                state: parse_portal_state(&portal.state)?,
                exterior: portal.exterior,
            });
        }

        let mut verticals = Vec::with_capacity(self.verticals.len());
        for v in &self.verticals {
            verticals.push(VerticalConnection {
                from_room: v.from_room,
                to_room: v.to_room,
                from_cell: cell_from_xyz(v.from_cell)?,
                to_cell: cell_from_xyz(v.to_cell)?,
            });
        }

        Ok(Topology {
            rooms,
            portals,
            verticals,
        })
    }

    /// Compact DTO from compiler Topology. `stable_ids` must be unique and non-empty.
    pub fn from_topology(
        topology: &Topology,
        stable_ids: &BTreeMap<RoomId, String>,
    ) -> Result<Self, String> {
        let mut seen_stable = BTreeSet::new();
        let mut rooms = Vec::with_capacity(topology.rooms.len());
        for room in &topology.rooms {
            let stable_id = stable_ids
                .get(&room.id)
                .ok_or_else(|| format!("missing stable_id for room {}", room.id))?;
            if stable_id.is_empty() {
                return Err(format!("room {} has empty stable_id", room.id));
            }
            if !seen_stable.insert(stable_id.clone()) {
                return Err(format!("duplicate stable_id '{stable_id}'"));
            }
            for cell in &room.cells {
                if cell.deck != room.deck {
                    return Err(format!(
                        "room {} cell {} deck disagrees with room deck {}",
                        room.id,
                        cell.key(),
                        room.deck
                    ));
                }
            }
            rooms.push(RoomSpecDto {
                id: room.id,
                stable_id: stable_id.clone(),
                role: room.role.name().to_string(),
                deck: room.deck,
                cells: room.cells.iter().map(|c| [c.x, c.y]).collect(),
            });
        }

        let portals = topology
            .portals
            .iter()
            .map(|p| PortalIntentDto {
                from_room: p.from_room,
                to_room: p.to_room,
                from_cell: cell_to_xyz(p.from_cell),
                to_cell: cell_to_xyz(p.to_cell),
                state: p.state.name().to_string(),
                exterior: p.exterior,
            })
            .collect();

        let verticals = topology
            .verticals
            .iter()
            .map(|v| VerticalConnectionDto {
                from_room: v.from_room,
                to_room: v.to_room,
                from_cell: cell_to_xyz(v.from_cell),
                to_cell: cell_to_xyz(v.to_cell),
            })
            .collect();

        Ok(Self {
            rooms,
            portals,
            verticals,
        })
    }
}

impl GoldenArea {
    pub fn room_stable_ids(&self) -> BTreeMap<RoomId, String> {
        self.topology
            .rooms
            .iter()
            .map(|r| (r.id, r.stable_id.clone()))
            .collect()
    }

    fn validate_document(&self) -> Result<(), String> {
        if self.schema_version != "1.0.0" {
            return Err(format!(
                "unsupported schema_version '{}'",
                self.schema_version
            ));
        }
        if self.document_kind != "golden_area" {
            return Err(format!(
                "document_kind '{}' must be golden_area",
                self.document_kind
            ));
        }
        if self.cell_size_m != CELL_SIZE_M {
            return Err(format!(
                "cell_size_m {} must equal {CELL_SIZE_M}",
                self.cell_size_m
            ));
        }
        if self.deck_height_m != DECK_HEIGHT_M {
            return Err(format!(
                "deck_height_m {} must equal {DECK_HEIGHT_M}",
                self.deck_height_m
            ));
        }
        let mut prop_ids = BTreeSet::new();
        let mut prop_cells = BTreeMap::new();
        for prop in &self.props {
            if !prop_ids.insert(prop.id) {
                return Err(format!("duplicate prop id {}", prop.id));
            }
            if let Some(previous_id) = prop_cells.insert(prop.cell, prop.id) {
                return Err(format!(
                    "props {} and {} share cell {:?}",
                    previous_id, prop.id, prop.cell
                ));
            }
            if prop.kind == EntityKind::Door {
                return Err(format!(
                    "prop {} has kind Door; doors are implied by portals",
                    prop.id
                ));
            }
        }
        self.validate_hazards()?;
        Ok(())
    }

    fn validate_hazards(&self) -> Result<(), String> {
        let mut rooms: BTreeMap<&str, (&RoomSpecDto, BTreeSet<[i32; 2]>)> = BTreeMap::new();
        for room in &self.topology.rooms {
            if room.stable_id.is_empty() {
                continue;
            }
            let cells = room.cells.iter().copied().collect();
            rooms.insert(room.stable_id.as_str(), (room, cells));
        }
        let mut ids = BTreeSet::new();
        let buckets: [(&str, &str, &[LinkZone]); 4] = [
            ("fire_zones", "timed_fire", &self.hazards.fire_zones),
            ("breach_zones", "hull_breach", &self.hazards.breach_zones),
            ("arc_zones", "electrical_arc", &self.hazards.arc_zones),
            (
                "radiation_zones",
                "radiation",
                &self.hazards.radiation_zones,
            ),
        ];
        for (bucket, expected_kind, zones) in buckets {
            for zone in zones {
                if zone.id.trim().is_empty() {
                    return Err(format!("{bucket} contains a zone with an empty id"));
                }
                if !ids.insert(zone.id.as_str()) {
                    return Err(format!("duplicate hazard id '{}'", zone.id));
                }
                if zone.kind != expected_kind {
                    return Err(format!(
                        "{bucket} zone '{}' has kind '{}'; expected '{expected_kind}'",
                        zone.id, zone.kind
                    ));
                }
                let Some((from_room, from_cells)) = rooms.get(zone.from_room.as_str()) else {
                    return Err(format!(
                        "{bucket} zone '{}' references unknown from_room '{}'",
                        zone.id, zone.from_room
                    ));
                };
                let Some((to_room, to_cells)) = rooms.get(zone.to_room.as_str()) else {
                    return Err(format!(
                        "{bucket} zone '{}' references unknown to_room '{}'",
                        zone.id, zone.to_room
                    ));
                };
                let from = hazard_cell(zone.from_cell, bucket, &zone.id)?;
                let to = hazard_cell(zone.to_cell, bucket, &zone.id)?;
                if from_room.deck != from.deck || !from_cells.contains(&[from.x, from.y]) {
                    return Err(format!(
                        "{bucket} zone '{}' from_cell {:?} is not owned by room '{}'",
                        zone.id, zone.from_cell, zone.from_room
                    ));
                }
                if from != to && Dir::between(from, to).is_none() {
                    return Err(format!(
                        "{bucket} zone '{}' endpoints {:?} -> {:?} are not adjacent",
                        zone.id, zone.from_cell, zone.to_cell
                    ));
                }
                let to_is_owned = to_room.deck == to.deck && to_cells.contains(&[to.x, to.y]);
                if !to_is_owned && !self.hazard_matches_exterior_portal(zone, from, to) {
                    return Err(format!(
                        "{bucket} zone '{}' to_cell {:?} is not owned by room '{}' or aligned with an exterior portal",
                        zone.id, zone.to_cell, zone.to_room
                    ));
                }
            }
        }
        Ok(())
    }

    fn hazard_matches_exterior_portal(&self, zone: &LinkZone, from: Cell, to: Cell) -> bool {
        if zone.to_room != zone.from_room {
            return false;
        }
        self.topology.portals.iter().any(|portal| {
            let Ok(portal_from) = hazard_cell(portal.from_cell, "portal", &zone.id) else {
                return false;
            };
            let Ok(portal_to) = hazard_cell(portal.to_cell, "portal", &zone.id) else {
                return false;
            };
            portal.exterior
                && portal.from_cell == zone.from_cell
                && portal.to_cell == zone.to_cell
                && portal_from == from
                && portal_to == to
                && self
                    .topology
                    .rooms
                    .iter()
                    .any(|room| room.id == portal.from_room && room.stable_id == zone.from_room)
        })
    }

    /// Room/area: missing `goal_room` defaults to entry; missing `entry_room`
    /// defaults to the first room's `stable_id`. Derelict requires both set.
    pub fn resolved_entry_goal(&self) -> Result<(String, String), String> {
        match self.scope {
            GoldenScope::Derelict => {
                if self.entry_room.is_empty() || self.goal_room.is_empty() {
                    return Err("scope derelict requires both entry_room and goal_room".into());
                }
                Ok((self.entry_room.clone(), self.goal_room.clone()))
            }
            GoldenScope::Room | GoldenScope::Area => {
                let entry = if self.entry_room.is_empty() {
                    self.topology
                        .rooms
                        .first()
                        .map(|r| r.stable_id.clone())
                        .unwrap_or_default()
                } else {
                    self.entry_room.clone()
                };
                if entry.is_empty() {
                    return Err("entry_room is empty and no rooms exist".into());
                }
                let goal = if self.goal_room.is_empty() {
                    entry.clone()
                } else {
                    self.goal_room.clone()
                };
                Ok((entry, goal))
            }
        }
    }

    /// Compiler Topology from this document. Duplicate/empty stable_id, unknown
    /// roles, and illegal portal states are load errors.
    pub fn to_topology(&self) -> Result<Topology, String> {
        self.validate_document()?;
        self.topology.to_topology()
    }

    /// Inverse of [`Self::to_topology`]: compact cells and Role/EdgeKind names.
    pub fn from_topology(
        topology: &Topology,
        stable_ids: &BTreeMap<RoomId, String>,
    ) -> Result<TopologyDto, String> {
        TopologyDto::from_topology(topology, stable_ids)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> GoldenArea {
        serde_json::from_str(include_str!("../../assets/golden_areas/airlock_2x2.json")).unwrap()
    }

    fn valid_fire() -> LinkZone {
        LinkZone {
            id: "fire_01".into(),
            from_room: "airlock_01".into(),
            to_room: "airlock_01".into(),
            from_cell: [0, 0, 0],
            to_cell: [1, 0, 0],
            module_id: String::new(),
            kind: "timed_fire".into(),
            compartment_id: String::new(),
            rationale: String::new(),
        }
    }

    #[test]
    fn hazard_zone_validates_kind_ownership_and_adjacency() {
        let mut golden = sample();
        golden.hazards.fire_zones.push(valid_fire());
        golden.to_topology().expect("valid authored hazard");

        let mut wrong_kind = golden.clone();
        wrong_kind.hazards.fire_zones[0].kind = "radiation".into();
        let error = wrong_kind.to_topology().unwrap_err();
        assert!(error.contains("expected 'timed_fire'"), "{error}");

        let mut wrong_owner = golden.clone();
        wrong_owner.hazards.fire_zones[0].from_cell = [9, 9, 0];
        let error = wrong_owner.to_topology().unwrap_err();
        assert!(error.contains("not owned"), "{error}");

        let mut non_adjacent = golden;
        non_adjacent.hazards.fire_zones[0].to_cell = [1, 1, 0];
        let error = non_adjacent.to_topology().unwrap_err();
        assert!(error.contains("not adjacent"), "{error}");
    }

    #[test]
    fn hazard_ids_are_nonempty_and_unique_across_buckets() {
        let mut golden = sample();
        let mut first = valid_fire();
        first.id.clear();
        golden.hazards.fire_zones.push(first);
        let error = golden.to_topology().unwrap_err();
        assert!(error.contains("empty id"), "{error}");

        let mut golden = sample();
        golden.hazards.fire_zones.push(valid_fire());
        let mut second = valid_fire();
        second.kind = "radiation".into();
        golden.hazards.radiation_zones.push(second);
        let error = golden.to_topology().unwrap_err();
        assert!(error.contains("duplicate hazard id"), "{error}");
    }

    #[test]
    fn collapsed_and_aligned_exterior_hazards_match_builder_hydration() {
        let mut collapsed = sample();
        let mut zone = valid_fire();
        zone.id = "collapsed_fire".into();
        zone.to_cell = zone.from_cell;
        collapsed.hazards.fire_zones.push(zone);
        collapsed.to_topology().expect("collapsed marker is valid");

        let mut exterior = sample();
        let mut zone = valid_fire();
        zone.id = "exterior_fire".into();
        zone.to_cell = [-1, 0, 0];
        exterior.hazards.fire_zones.push(zone);
        exterior
            .to_topology()
            .expect("aligned exterior marker is valid");

        let mut unaligned = sample();
        let mut zone = valid_fire();
        zone.id = "unaligned_exterior_fire".into();
        zone.to_cell = [-2, 0, 0];
        unaligned.hazards.fire_zones.push(zone);
        let error = unaligned.to_topology().unwrap_err();
        assert!(error.contains("not adjacent"), "{error}");
    }
}
