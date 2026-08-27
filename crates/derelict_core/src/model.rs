//! Core data model for generated derelict ships.
//!
//! Determinism contract: every type here is plain data (integer coordinates,
//! fixed-point scalars, ordered collections). Nothing in this module may hold
//! a float or an unordered collection — generated ships must serialize to
//! byte-identical output for identical (seed, params, GENERATOR_VERSION).

use crate::authoring::AuthoredHazards;
use crate::role::Role;
use crate::structural::plan::{RoomId, StructuralPlan, Topology};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Bumped on ANY change that alters generated output (stage logic, RNG
/// consumption order, archetype schema). Baked into ships and save diffs.
pub const GENERATOR_VERSION: u32 = 4;

/// Intactness is fixed-point: 0..=10000 basis points (10000 = pristine).
pub type Intactness = u16;
pub const INTACT_MAX: Intactness = 10_000;

pub type TileCoord = i32;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Serialize, Deserialize)]
pub struct GridPos {
    pub x: TileCoord,
    pub y: TileCoord,
    pub deck: u8,
}

impl GridPos {
    pub fn new(x: TileCoord, y: TileCoord, deck: u8) -> Self {
        Self { x, y, deck }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
#[repr(u8)]
pub enum FloorTile {
    /// Open space / no floor (outside hull, or a breach hole).
    #[default]
    Void = 0,
    Deck = 1,
    Grated = 2,
    DamagedDeck = 3,
}

impl FloorTile {
    pub fn walkable(self) -> bool {
        !matches!(self, FloorTile::Void)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
#[repr(u8)]
pub enum WallEdge {
    #[default]
    None = 0,
    /// Exterior hull wall.
    Hull = 1,
    /// Interior partition wall.
    Interior = 2,
    /// Door frame opening (a Door entity sits on this edge).
    Doorway = 3,
    /// Wall destroyed by damage; passable, jagged.
    Breached = 4,
}

impl WallEdge {
    pub fn blocks(self) -> bool {
        matches!(self, WallEdge::Hull | WallEdge::Interior)
    }
    pub fn is_wall(self) -> bool {
        !matches!(self, WallEdge::None)
    }
}

/// PZ-style: walls live on tile EDGES. Each tile stores its north and west
/// edges; a tile's south edge is its south neighbor's north edge, etc.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default, Serialize, Deserialize)]
pub struct TileWalls {
    pub north: WallEdge,
    pub west: WallEdge,
}

/// Decal overlay ids for the decal tile layer.
pub mod decal {
    pub const NONE: u8 = 0;
    pub const SCORCH_LIGHT: u8 = 1;
    pub const SCORCH_HEAVY: u8 = 2;
    pub const BLOOD: u8 = 3;
    pub const DEBRIS_SCATTER: u8 = 4;
}

pub const NO_ROOM: u16 = 0;

/// One deck's tile data as flat row-major arrays (index = y * width + x).
#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct DeckLayer {
    pub width: u16,
    pub height: u16,
    pub floor: Vec<FloorTile>,
    pub walls: Vec<TileWalls>,
    /// Room id per tile; NO_ROOM (0) = not part of any room (void/space).
    pub room_id: Vec<u16>,
    pub decal: Vec<u8>,
}

impl DeckLayer {
    pub fn new(width: u16, height: u16) -> Self {
        let n = width as usize * height as usize;
        Self {
            width,
            height,
            floor: vec![FloorTile::Void; n],
            walls: vec![TileWalls::default(); n],
            room_id: vec![NO_ROOM; n],
            decal: vec![decal::NONE; n],
        }
    }

    #[inline]
    pub fn idx(&self, x: TileCoord, y: TileCoord) -> Option<usize> {
        if x < 0 || y < 0 || x >= self.width as i32 || y >= self.height as i32 {
            None
        } else {
            Some(y as usize * self.width as usize + x as usize)
        }
    }

    pub fn floor_at(&self, x: TileCoord, y: TileCoord) -> FloorTile {
        self.idx(x, y)
            .map(|i| self.floor[i])
            .unwrap_or(FloorTile::Void)
    }

    pub fn room_at(&self, x: TileCoord, y: TileCoord) -> u16 {
        self.idx(x, y).map(|i| self.room_id[i]).unwrap_or(NO_ROOM)
    }

    pub fn walls_at(&self, x: TileCoord, y: TileCoord) -> TileWalls {
        self.idx(x, y).map(|i| self.walls[i]).unwrap_or_default()
    }

    /// The wall edge on a given side of tile (x, y).
    pub fn edge(&self, x: TileCoord, y: TileCoord, side: Side) -> WallEdge {
        match side {
            Side::North => self.walls_at(x, y).north,
            Side::West => self.walls_at(x, y).west,
            Side::South => self.walls_at(x, y + 1).north,
            Side::East => self.walls_at(x + 1, y).west,
        }
    }

    pub fn set_edge(&mut self, x: TileCoord, y: TileCoord, side: Side, w: WallEdge) {
        let (tx, ty, north) = match side {
            Side::North => (x, y, true),
            Side::West => (x, y, false),
            Side::South => (x, y + 1, true),
            Side::East => (x + 1, y, false),
        };
        if let Some(i) = self.idx(tx, ty) {
            if north {
                self.walls[i].north = w;
            } else {
                self.walls[i].west = w;
            }
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum Side {
    North,
    South,
    East,
    West,
}

impl Side {
    pub const ALL: [Side; 4] = [Side::North, Side::South, Side::East, Side::West];
    pub fn delta(self) -> (i32, i32) {
        match self {
            Side::North => (0, -1),
            Side::South => (0, 1),
            Side::East => (1, 0),
            Side::West => (-1, 0),
        }
    }
}

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct RoomNode {
    pub id: u16,
    pub deck: u8,
    pub kind: Role,
    /// AABB in deck-local tile coords (min inclusive, max inclusive).
    pub min: (TileCoord, TileCoord),
    pub max: (TileCoord, TileCoord),
    pub tile_count: u32,
    pub depressurized: bool,
    /// For multi-deck logical systems (engineering spanning decks): the room
    /// id of the same logical room on the deck below, if any.
    pub spans_room_id: Option<u16>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum EdgeKind {
    Door,
    OpenCorridor,
    VerticalShaft,
    Breach,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub struct RoomEdge {
    pub a: u16,
    pub b: u16,
    pub kind: EdgeKind,
}

#[derive(Clone, PartialEq, Debug, Default, Serialize, Deserialize)]
pub struct RoomGraph {
    pub nodes: Vec<RoomNode>,
    pub edges: Vec<RoomEdge>,
}

impl RoomGraph {
    pub fn node(&self, id: u16) -> Option<&RoomNode> {
        self.nodes.iter().find(|n| n.id == id)
    }
    pub fn node_mut(&mut self, id: u16) -> Option<&mut RoomNode> {
        self.nodes.iter_mut().find(|n| n.id == id)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Serialize, Deserialize)]
pub enum EntityKind {
    Door,
    Container,
    Terminal,
    Furniture,
    Debris,
    Body,
    ItemPile,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Serialize, Deserialize)]
pub struct ItemStack {
    pub item_id: u32,
    pub qty: u16,
}

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct EntitySpec {
    /// Stable within this ship; assigned in deterministic order. Save diffs
    /// and co-op mutation replication address entities by this id.
    pub id: u32,
    pub kind: EntityKind,
    /// Prototype key, maps to a scene/visual on the Godot side ("bed",
    /// "locker", "helm_console", "hull_plate_debris", ...).
    pub proto: String,
    pub pos: GridPos,
    /// 0..=3, 90-degree steps. For doors: 0 = sits on north edge of pos,
    /// 1 = west edge.
    pub rotation: u8,
    pub locked: bool,
    pub open: bool,
    pub inventory: Vec<ItemStack>,
    pub tags: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum CauseOfLoss {
    ReactorBreach,
    Depressurization,
    PirateBoarding,
    Plague,
    DriveMisjump,
    Unknown,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum DamageEventKind {
    Breach,
    ScorchZone,
    StructuralFracture,
    DebrisField,
}

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct DamageEvent {
    pub kind: DamageEventKind,
    pub deck: u8,
    pub origin: (TileCoord, TileCoord),
    pub radius: u16,
}

/// Metadata about one hull piece after a structural fracture. Tile data is
/// already laid out in final world-local coordinates (fragments are baked
/// apart into the shared deck grid), so this exists for debugging/AI hints,
/// not for rendering math.
#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct ShipFragment {
    pub id: u8,
    /// Room ids belonging to this fragment.
    pub rooms: Vec<u16>,
    /// Translation that was applied to this fragment when baking it apart.
    pub drift: (TileCoord, TileCoord),
}

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct Deck {
    pub layer: DeckLayer,
}

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct Ship {
    pub generator_version: u32,
    pub seed: u64,
    pub archetype_id: String,
    /// Topology template that authored this ship.
    pub template_id: String,
    pub intactness: Intactness,
    pub cause_of_loss: CauseOfLoss,
    /// Authored topology (rooms with explicit occupancy, portal intents,
    /// vertical connections) — the compile input, kept for validation and
    /// export cross-checks.
    pub topology: Topology,
    /// The canonical structural plan — the AUTHORITATIVE geometry. Deck
    /// raster layers below are a derived projection of this.
    pub plan: StructuralPlan,
    pub entry_room: RoomId,
    pub goal_room: RoomId,
    pub critical_path: Vec<RoomId>,
    pub decks: Vec<Deck>,
    pub room_graph: RoomGraph,
    pub entities: Vec<EntitySpec>,
    pub damage_events: Vec<DamageEvent>,
    pub fractured: bool,
    pub fragments: Vec<ShipFragment>,
    /// Authored LinkZones from occupancy stamps. `to_layout_json` merges these
    /// into overlay arrays; `hazard_source` stays `"runtime"` on generated ships.
    #[serde(default)]
    pub hazard_overlay: AuthoredHazards,
}

impl Ship {
    pub fn entity(&self, id: u32) -> Option<&EntitySpec> {
        self.entities.iter().find(|e| e.id == id)
    }
}

/// Generation request parameters (everything besides the seed).
#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct GenParams {
    pub archetype_id: String,
    /// None = rolled from seed.
    pub intactness_override: Option<Intactness>,
    pub cause_override: Option<CauseOfLoss>,
    /// Loot richness in basis points (10000 = normal).
    pub loot_richness: u16,
}

impl GenParams {
    pub fn new(archetype_id: &str) -> Self {
        Self {
            archetype_id: archetype_id.to_string(),
            intactness_override: None,
            cause_override: None,
            loot_richness: 10_000,
        }
    }
}

// ---------------------------------------------------------------------------
// Persistence: mutation diffs
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum TileDestruction {
    FloorBreached,
    WallBreached { side_north: bool },
}

/// Everything that can change about a ship after generation. The base ship is
/// never saved — only this diff. Ordered collections only (byte-stable
/// serialization; diffs are hashed for co-op sync verification).
#[derive(Clone, PartialEq, Debug, Default, Serialize, Deserialize)]
pub struct ShipMutationDiff {
    pub generator_version: u32,
    pub seed: u64,
    pub door_open: BTreeMap<u32, bool>,
    pub door_locked: BTreeMap<u32, bool>,
    /// Full-replace inventory per container entity id.
    pub container_inventory: BTreeMap<u32, Vec<ItemStack>>,
    pub removed_entities: BTreeSet<u32>,
    pub destroyed_tiles: Vec<(GridPos, TileDestruction)>,
}

impl ShipMutationDiff {
    pub fn for_ship(ship: &Ship) -> Self {
        Self {
            generator_version: ship.generator_version,
            seed: ship.seed,
            ..Default::default()
        }
    }

    pub fn is_empty(&self) -> bool {
        self.door_open.is_empty()
            && self.door_locked.is_empty()
            && self.container_inventory.is_empty()
            && self.removed_entities.is_empty()
            && self.destroyed_tiles.is_empty()
    }
}

/// Apply a mutation diff to a freshly regenerated base ship. Application
/// order is fixed and documented: locks, open states, inventories, removed
/// entities, destroyed tiles. Unknown entity ids are skipped (generator
/// version drift), never a panic.
pub fn apply_diff(ship: &mut Ship, diff: &ShipMutationDiff) {
    for (id, locked) in &diff.door_locked {
        if let Some(e) = ship.entities.iter_mut().find(|e| e.id == *id) {
            e.locked = *locked;
        }
    }
    for (id, open) in &diff.door_open {
        if let Some(e) = ship.entities.iter_mut().find(|e| e.id == *id) {
            e.open = *open;
            // Keep the wall edge passable state in sync for doors.
        }
    }
    for (id, inv) in &diff.container_inventory {
        if let Some(e) = ship.entities.iter_mut().find(|e| e.id == *id) {
            e.inventory = inv.clone();
        }
    }
    ship.entities
        .retain(|e| !diff.removed_entities.contains(&e.id));
    for (pos, destruction) in &diff.destroyed_tiles {
        let deck_i = pos.deck as usize;
        if deck_i >= ship.decks.len() {
            continue;
        }
        let layer = &mut ship.decks[deck_i].layer;
        let Some(i) = layer.idx(pos.x, pos.y) else {
            continue;
        };
        match destruction {
            TileDestruction::FloorBreached => layer.floor[i] = FloorTile::DamagedDeck,
            TileDestruction::WallBreached { side_north } => {
                if *side_north {
                    layer.walls[i].north = WallEdge::Breached;
                } else {
                    layer.walls[i].west = WallEdge::Breached;
                }
            }
        }
    }
}
