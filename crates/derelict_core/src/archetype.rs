//! Data-driven generation content: ship archetypes, furnishing rules, loot
//! tables. All authored as RON files; defaults are embedded in the binary so
//! the generator works with zero filesystem setup, and can be overridden by
//! loading replacement RON at runtime (modding / game-side tuning).

use crate::authoring::GoldenArea;
use crate::model::{CauseOfLoss, EntityKind};
use crate::role::Role;
use crate::topology::TemplateSet;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ShipArchetype {
    pub id: String,
    pub display_name: String,
    /// Deck-0 hull length range (cells along x; 1 cell = 4 m).
    pub length: (u16, u16),
    /// Deck-0 hull beam range (cells along y).
    pub beam: (u16, u16),
    pub decks: (u8, u8),
    /// Fraction of the hull envelope to fill with cells, basis points.
    pub hull_fill_bp: u16,
    /// Probability per growth step of skipping the mirrored twin, bp.
    pub asymmetry_bp: u16,
    /// Boundary erosion (cells) applied per deck away from the main deck.
    pub deck_erosion: u8,
    /// Optional fixed template; empty = seeded pick from compatible set.
    pub template: String,
    /// Role weights for zone role-pool picks.
    pub role_weights: Vec<(Role, u32)>,
    /// Roles that MUST exist on every ship of this archetype. Load-time
    /// validation guarantees at least one template can satisfy them.
    pub guaranteed_roles: Vec<Role>,
    /// Max rooms sharing a role (0 = unlimited).
    pub max_duplicates: u8,
    /// (role, weight) pool for residual-space filler rooms.
    pub filler_roles: Vec<(Role, u32)>,
    pub cause_weights: Vec<(CauseOfLoss, u32)>,
    /// Max breach count at intactness 0.
    pub max_breaches: u8,
    /// Golden-area ids to stamp into compatible rooms. Empty = no stamps
    /// (default archetypes stay unstamped until a fixture opts in).
    #[serde(default)]
    pub golden_stamps: Vec<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
pub enum Placement {
    WallAdjacent,
    Corner,
    Center,
    Free,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct FurnitureRule {
    pub proto: String,
    pub kind: EntityKind,
    pub count: (u8, u8),
    pub place: Placement,
    /// For containers: chance the container is locked, bp.
    pub lock_bp: u16,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct FurnishingRules {
    pub rules: BTreeMap<Role, Vec<FurnitureRule>>,
    pub door_lock_bp: BTreeMap<Role, u16>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ItemDef {
    pub id: u32,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LootEntry {
    /// Item name; resolved against the item registry at load time.
    pub item: String,
    pub weight: u32,
    pub qty: (u16, u16),
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct LootTables {
    /// Per room type: pool of possible items for containers in that room.
    pub tables: BTreeMap<Role, Vec<LootEntry>>,
    /// Rolls per container, before richness scaling.
    pub rolls: (u8, u8),
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ItemRegistry {
    pub items: Vec<ItemDef>,
}

impl ItemRegistry {
    pub fn id_of(&self, name: &str) -> Option<u32> {
        self.items.iter().find(|i| i.name == name).map(|i| i.id)
    }
    pub fn name_of(&self, id: u32) -> Option<&str> {
        self.items
            .iter()
            .find(|i| i.id == id)
            .map(|i| i.name.as_str())
    }
}

/// The full bundle of generation content data.
#[derive(Clone, Debug)]
pub struct GenData {
    pub archetypes: BTreeMap<String, ShipArchetype>,
    pub templates: TemplateSet,
    pub furnishing: FurnishingRules,
    pub loot: LootTables,
    pub items: ItemRegistry,
    pub golden_areas: BTreeMap<String, GoldenArea>,
}

#[derive(Debug)]
pub enum DataError {
    Parse(String),
    Validation(String),
}

impl std::fmt::Display for DataError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DataError::Parse(m) => write!(f, "data parse error: {m}"),
            DataError::Validation(m) => write!(f, "data validation error: {m}"),
        }
    }
}

impl std::error::Error for DataError {}

const DEFAULT_ARCHETYPES: &[&str] = &[
    include_str!("../assets/archetypes/shuttle.ron"),
    include_str!("../assets/archetypes/corvette.ron"),
    include_str!("../assets/archetypes/freighter.ron"),
    include_str!("../assets/archetypes/frigate.ron"),
];
const DEFAULT_FURNISHING: &str = include_str!("../assets/furnishing_rules/default.ron");
const DEFAULT_LOOT: &str = include_str!("../assets/loot_tables/default.ron");
const DEFAULT_ITEMS: &str = include_str!("../assets/items.ron");
const DEFAULT_GOLDENS: &[&str] = &[include_str!("../assets/golden_areas/airlock_2x2.json")];

impl GenData {
    /// Load the embedded default content bundle.
    pub fn default_bundle() -> Result<Self, DataError> {
        let mut archetypes = BTreeMap::new();
        for src in DEFAULT_ARCHETYPES {
            let a: ShipArchetype =
                ron::from_str(src).map_err(|e| DataError::Parse(e.to_string()))?;
            archetypes.insert(a.id.clone(), a);
        }
        let furnishing: FurnishingRules =
            ron::from_str(DEFAULT_FURNISHING).map_err(|e| DataError::Parse(e.to_string()))?;
        let loot: LootTables =
            ron::from_str(DEFAULT_LOOT).map_err(|e| DataError::Parse(e.to_string()))?;
        let items: ItemRegistry =
            ron::from_str(DEFAULT_ITEMS).map_err(|e| DataError::Parse(e.to_string()))?;
        let templates = TemplateSet::default_bundle().map_err(DataError::Parse)?;
        let mut golden_areas = BTreeMap::new();
        for src in DEFAULT_GOLDENS {
            let g: GoldenArea =
                serde_json::from_str(src).map_err(|e| DataError::Parse(e.to_string()))?;
            golden_areas.insert(g.id.clone(), g);
        }
        let data = Self {
            archetypes,
            templates,
            furnishing,
            loot,
            items,
            golden_areas,
        };
        data.validate()?;
        Ok(data)
    }

    /// Validate authored content so unsatisfiable data fails at load, not
    /// mid-generation: room tile budgets fit the smallest hull, loot items
    /// resolve, weights are non-degenerate.
    pub fn validate(&self) -> Result<(), DataError> {
        for (id, a) in &self.archetypes {
            if a.length.0 < 6 || a.beam.0 < 4 {
                return Err(DataError::Validation(format!(
                    "archetype '{id}': hull too small (min 6x4 cells)"
                )));
            }
            if a.length.0 > a.length.1 || a.beam.0 > a.beam.1 || a.decks.0 > a.decks.1 {
                return Err(DataError::Validation(format!(
                    "archetype '{id}': inverted range"
                )));
            }
            if a.cause_weights.iter().map(|(_, w)| *w as u64).sum::<u64>() == 0 {
                return Err(DataError::Validation(format!(
                    "archetype '{id}': cause_weights all zero"
                )));
            }
            // Fail-closed guarantee contract: at MINIMUM deck count, at
            // least one template must satisfy every guaranteed role — the
            // structural fix for the Synaptic Sea silently-skipped-dock bug.
            if !a.template.is_empty() {
                let t = self.templates.templates.get(&a.template).ok_or_else(|| {
                    DataError::Validation(format!(
                        "archetype '{id}': unknown template '{}'",
                        a.template
                    ))
                })?;
                if !t.can_satisfy(&a.guaranteed_roles) {
                    return Err(DataError::Validation(format!(
                        "archetype '{id}': pinned template '{}' cannot satisfy guaranteed roles",
                        a.template
                    )));
                }
                if t.max_zone_deck() >= a.decks.0 {
                    return Err(DataError::Validation(format!(
                        "archetype '{id}': pinned template '{}' needs more decks than min {}",
                        a.template, a.decks.0
                    )));
                }
            } else if self
                .templates
                .compatible(&a.guaranteed_roles, a.decks.0)
                .is_empty()
            {
                return Err(DataError::Validation(format!(
                    "archetype '{id}': no template can satisfy guaranteed roles {:?} at {} deck(s)",
                    a.guaranteed_roles, a.decks.0
                )));
            }
            for stamp_id in &a.golden_stamps {
                if !self.golden_areas.contains_key(stamp_id) {
                    return Err(DataError::Validation(format!(
                        "archetype '{id}': unknown golden stamp '{stamp_id}'"
                    )));
                }
            }
        }
        for (room, entries) in &self.loot.tables {
            for e in entries {
                if self.items.id_of(&e.item).is_none() {
                    return Err(DataError::Validation(format!(
                        "loot table {room:?}: unknown item '{}'",
                        e.item
                    )));
                }
            }
        }
        Ok(())
    }
}
