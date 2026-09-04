//! The canonical structural plan IR — ported from The Synaptic Sea's
//! `structural_edge_plan.gd` / `structural_edge_compiler.gd` design.
//!
//! Core invariant: a boundary is identified GEOMETRICALLY, never by which
//! room reached it first — both sides of a shared cell edge derive the same
//! `edge_key`, so every wall/portal exists exactly once.
//!
//! World positions are pure functions of integer grid coordinates (exact in
//! f32 at these magnitudes) — geometry output, never RNG-decision input, so
//! the no-floats-in-decisions determinism rule is preserved.

use crate::role::Role;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Grid scale matching The Synaptic Sea's module kit.
pub const CELL_SIZE_M: f32 = 4.0;
pub const DECK_HEIGHT_M: f32 = 4.0;

pub type RoomId = u16;
pub const NO_ROOM: RoomId = 0;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Serialize, Deserialize)]
pub struct Cell {
    pub deck: u8,
    pub x: i32,
    pub y: i32,
}

impl Cell {
    pub fn new(deck: u8, x: i32, y: i32) -> Self {
        Self { deck, x, y }
    }

    /// Canonical occupancy identity: "deck|x|y".
    pub fn key(self) -> String {
        format!("{}|{}|{}", self.deck, self.x, self.y)
    }

    pub fn world_pos(self) -> [f32; 3] {
        [
            self.x as f32 * CELL_SIZE_M,
            self.deck as f32 * DECK_HEIGHT_M,
            self.y as f32 * CELL_SIZE_M,
        ]
    }

    pub fn neighbor(self, dir: Dir) -> Cell {
        let (dx, dy) = dir.delta();
        Cell::new(self.deck, self.x + dx, self.y + dy)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Serialize, Deserialize)]
pub enum Dir {
    North,
    South,
    East,
    West,
}

impl Dir {
    pub const ALL: [Dir; 4] = [Dir::North, Dir::East, Dir::South, Dir::West];

    pub fn delta(self) -> (i32, i32) {
        match self {
            Dir::North => (0, -1),
            Dir::South => (0, 1),
            Dir::East => (1, 0),
            Dir::West => (-1, 0),
        }
    }

    pub fn opposite(self) -> Dir {
        match self {
            Dir::North => Dir::South,
            Dir::South => Dir::North,
            Dir::East => Dir::West,
            Dir::West => Dir::East,
        }
    }

    /// Module yaw convention (south = zero pose), matching the game kit.
    pub fn yaw_degrees(self) -> u16 {
        match self {
            Dir::South => 0,
            Dir::West => 90,
            Dir::North => 180,
            Dir::East => 270,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Dir::North => "north",
            Dir::South => "south",
            Dir::East => "east",
            Dir::West => "west",
        }
    }

    pub fn parse(s: &str) -> Option<Dir> {
        match s {
            "north" => Some(Dir::North),
            "south" => Some(Dir::South),
            "east" => Some(Dir::East),
            "west" => Some(Dir::West),
            _ => None,
        }
    }

    /// Direction from `a` to a cardinal neighbor `b` on the same deck.
    pub fn between(a: Cell, b: Cell) -> Option<Dir> {
        if a.deck != b.deck {
            return None;
        }
        match (b.x - a.x, b.y - a.y) {
            (0, -1) => Some(Dir::North),
            (0, 1) => Some(Dir::South),
            (1, 0) => Some(Dir::East),
            (-1, 0) => Some(Dir::West),
            _ => None,
        }
    }
}

/// Geometric boundary identity: both sides of a shared edge produce the SAME
/// key. North/south boundaries: "deck|h|min(y,ny)|x"; east/west:
/// "deck|v|y|min(x,nx)". Ported 1:1 from structural_edge_plan.gd.
pub fn edge_key(cell: Cell, dir: Dir) -> String {
    let n = cell.neighbor(dir);
    match dir {
        Dir::North | Dir::South => {
            format!("{}|h|{}|{}", cell.deck, cell.y.min(n.y), cell.x)
        }
        Dir::East | Dir::West => {
            format!("{}|v|{}|{}", cell.deck, cell.y, cell.x.min(n.x))
        }
    }
}

/// World-space midpoint of a cell edge (half a cell toward the boundary).
pub fn edge_world_position(cell: Cell, dir: Dir) -> [f32; 3] {
    let c = cell.world_pos();
    let (dx, dy) = dir.delta();
    [
        c[0] + dx as f32 * CELL_SIZE_M * 0.5,
        c[1],
        c[2] + dy as f32 * CELL_SIZE_M * 0.5,
    ]
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Serialize, Deserialize)]
pub enum EdgeKind {
    Solid,
    /// Interior of a multi-cell room: no wall, never materialized.
    Open,
    Door,
    Locked,
    Hatch,
    Breach,
}

impl EdgeKind {
    pub fn name(self) -> &'static str {
        match self {
            EdgeKind::Solid => "SOLID",
            EdgeKind::Open => "OPEN",
            EdgeKind::Door => "DOOR",
            EdgeKind::Locked => "LOCKED",
            EdgeKind::Hatch => "HATCH",
            EdgeKind::Breach => "BREACH",
        }
    }

    /// Passable to a standing player in the game.
    pub fn standing_passable(self) -> bool {
        matches!(self, EdgeKind::Open | EdgeKind::Door | EdgeKind::Hatch)
    }
}

/// Asset damage variant, resolved at export time against the kit's
/// intact/damaged/breached module variants. Structural role (`module_id`)
/// stays stable; only the rendered asset changes.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub enum DamageVariant {
    #[default]
    Intact,
    Damaged,
    Breached,
}

/// One occupied cell.
#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct CellRecord {
    pub cell: Cell,
    pub room_id: RoomId,
    pub module_id: String,
    /// Cosmetic damage decal id (never affects validation/topology).
    pub decal: u8,
    pub variant: DamageVariant,
}

/// One canonical boundary.
#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct EdgeRecord {
    pub edge_key: String,
    pub kind: EdgeKind,
    pub module_id: String,
    pub variant: DamageVariant,
    pub position: [f32; 3],
    pub yaw_degrees: u16,
    /// The cell/direction this edge was first derived from (either side is
    /// valid; edge_key is what's canonical).
    pub cell: Cell,
    pub direction: Dir,
    /// (owning-side room, other-side room); NO_ROOM = exterior/void.
    pub room_ids: (RoomId, RoomId),
    pub source_cells: [Cell; 2],
    pub portal: bool,
    pub exterior: bool,
    /// Whether this edge demands a materialized placement (Open and BREACH
    /// holes don't).
    pub wrapper_required: bool,
}

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct FloorPlacement {
    pub id: String, // "floor:<cell_key>"
    pub cell: Cell,
    pub cell_key: String,
    pub room_id: RoomId,
    pub module_id: String,
    pub position: [f32; 3],
    pub yaw_degrees: u16,
    pub variant: DamageVariant,
}

pub type CeilingPlacement = FloorPlacement; // "ceiling:<cell_key>" ids

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct SocketBinding {
    pub placement_id: String,
    pub socket_id: String,
    pub neighbor_placement_id: String,
    pub neighbor_socket_id: String,
    pub kind: String,
}

#[derive(Clone, PartialEq, Debug, Default, Serialize, Deserialize)]
pub struct StructuralPlan {
    pub occupancy: BTreeMap<String, CellRecord>,
    pub edges: BTreeMap<String, EdgeRecord>,
    /// Materialized non-Open, wrapper-required edges (sorted by edge_key).
    pub placements: Vec<EdgeRecord>,
    pub floor_placements: Vec<FloorPlacement>,
    pub ceiling_placements: Vec<CeilingPlacement>,
    pub socket_bindings: Vec<SocketBinding>,
    /// Compiler diagnostics; non-empty fails validation.
    pub errors: Vec<String>,
}

// ---------------------------------------------------------------------------
// Compiler input: authored topology (rooms with explicit occupancy, portal
// intents, vertical connections).
// ---------------------------------------------------------------------------

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct RoomSpec {
    pub id: RoomId,
    pub role: Role,
    pub deck: u8,
    pub cells: Vec<Cell>,
}

/// Authored doorway between two rooms sharing a real cardinal cell edge.
/// Created at placement time by the topology stage — never derived post-hoc.
#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct PortalIntent {
    pub from_room: RoomId,
    pub to_room: RoomId,
    pub from_cell: Cell,
    pub to_cell: Cell,
    pub state: EdgeKind, // Door | Locked | Hatch | Breach
    /// Exterior door (to_room == NO_ROOM): airlock onto space.
    pub exterior: bool,
}

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct VerticalConnection {
    pub from_room: RoomId,
    pub to_room: RoomId,
    pub from_cell: Cell,
    pub to_cell: Cell,
}

/// Everything the structural compiler consumes.
#[derive(Clone, PartialEq, Debug, Default, Serialize, Deserialize)]
pub struct Topology {
    pub rooms: Vec<RoomSpec>,
    pub portals: Vec<PortalIntent>,
    pub verticals: Vec<VerticalConnection>,
}

impl Topology {
    pub fn room(&self, id: RoomId) -> Option<&RoomSpec> {
        self.rooms.iter().find(|r| r.id == id)
    }
}
