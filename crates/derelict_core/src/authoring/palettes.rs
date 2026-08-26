//! Builder palettes ingested from kit JSON, prop maps, visual bindings, and items.ron.

use crate::archetype::{FurnishingRules, ItemRegistry};
use crate::authoring::proto_map::load_proto_visual_map;
use crate::structural::sockets::SocketCatalog;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

const DEFAULT_FURNISHING: &str = include_str!("../../assets/furnishing_rules/default.ron");
const DEFAULT_ITEMS: &str = include_str!("../../assets/items.ron");

#[derive(Clone, Debug, Default)]
pub struct AuthorPalettes {
    pub kit: BuilderKitCatalog,
    pub sockets: SocketCatalog,
    pub furnishing: FurnishingRules,
    pub proto_visual: BTreeMap<String, String>,
    pub visuals: VisualBindingIndex,
    pub items: BTreeMap<String, ItemPaletteEntry>,
    pub loot_tables: Vec<String>,
    pub recipes_ingredients: BTreeSet<String>,
    pub components: BTreeMap<String, ComponentPaletteEntry>,
    pub gameplay_props: BTreeMap<String, GameplayPropEntry>,
}

/// Kit catalog that keeps `module_family` / `footprint_cells` (`sockets::KitCatalog` drops them).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct BuilderKitCatalog {
    #[serde(default)]
    pub kit_id: String,
    #[serde(default)]
    pub modules: Vec<BuilderKitModule>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct BuilderKitModule {
    pub module_id: String,
    #[serde(default)]
    pub module_family: String,
    #[serde(default)]
    pub footprint_cells: Vec<u32>,
    #[serde(default)]
    pub godot_wrapper_scene: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct GameplayPropEntry {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub mesh_path: String,
    #[serde(default)]
    pub primitive: String,
    #[serde(default)]
    pub albedo: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ItemPaletteEntry {
    pub item_id: String,
    pub display_name: String,
    pub category: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
pub struct VisualBindingIndex {
    #[serde(default)]
    pub components: BTreeMap<String, VisualBinding>,
    #[serde(default)]
    pub dressing: BTreeMap<String, VisualBinding>,
    #[serde(default)]
    pub objectives: BTreeMap<String, VisualBinding>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct VisualBinding {
    pub asset_id: String,
    pub visual_scene_path: String,
    pub allowed_yaw_deg: Vec<f32>,
    pub surface: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct ComponentPaletteEntry {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub slot: String,
}

impl<'de> Deserialize<'de> for VisualBinding {
    fn deserialize<D: serde::de::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        struct Raw {
            #[serde(default)]
            asset_id: String,
            #[serde(default)]
            visual_scene_path: String,
            #[serde(default)]
            placement: PlacementRaw,
        }
        #[derive(Deserialize, Default)]
        struct PlacementRaw {
            #[serde(default)]
            allowed_yaw_deg: Vec<f32>,
            #[serde(default)]
            surface: Option<String>,
        }
        let raw = Raw::deserialize(deserializer)?;
        Ok(Self {
            asset_id: raw.asset_id,
            visual_scene_path: raw.visual_scene_path,
            allowed_yaw_deg: raw.placement.allowed_yaw_deg,
            surface: raw.placement.surface,
        })
    }
}

impl AuthorPalettes {
    /// Embedded furnishing rules, proto map, and `items.ron` names. No content root.
    pub fn offline() -> Result<Self, String> {
        Ok(Self {
            kit: BuilderKitCatalog::default(),
            sockets: SocketCatalog::default(),
            furnishing: ron::from_str(DEFAULT_FURNISHING).map_err(|e| e.to_string())?,
            proto_visual: load_proto_visual_map()?,
            visuals: VisualBindingIndex::default(),
            items: ItemPaletteEntry::offline()?,
            loot_tables: Vec::new(),
            recipes_ingredients: BTreeSet::new(),
            components: BTreeMap::new(),
            gameplay_props: BTreeMap::new(),
        })
    }
}

impl BuilderKitCatalog {
    pub fn from_json(text: &str) -> Result<Self, String> {
        serde_json::from_str(text).map_err(|e| format!("kit catalog: {e}"))
    }

    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
        Self::from_json(&text)
    }

    pub fn module(&self, module_id: &str) -> Option<&BuilderKitModule> {
        self.modules.iter().find(|m| m.module_id == module_id)
    }
}

impl GameplayPropEntry {
    /// `gameplay_prop_v0.json` is a `props` map, not a kit `modules` array.
    pub fn load_map(text: &str) -> Result<BTreeMap<String, Self>, String> {
        #[derive(Deserialize)]
        struct File {
            #[serde(default)]
            props: BTreeMap<String, GameplayPropEntry>,
        }
        let file: File = serde_json::from_str(text).map_err(|e| format!("gameplay props: {e}"))?;
        Ok(file
            .props
            .into_iter()
            .map(|(id, mut entry)| {
                entry.id = id.clone();
                (id, entry)
            })
            .collect())
    }
}

impl ItemPaletteEntry {
    pub fn from_items_ron(text: &str) -> Result<BTreeMap<String, Self>, String> {
        let registry: ItemRegistry = ron::from_str(text).map_err(|e| format!("items.ron: {e}"))?;
        Ok(registry
            .items
            .into_iter()
            .map(|item| {
                let id = item.name;
                (
                    id.clone(),
                    Self {
                        item_id: id.clone(),
                        display_name: id,
                        category: String::new(),
                    },
                )
            })
            .collect())
    }

    pub fn offline() -> Result<BTreeMap<String, Self>, String> {
        Self::from_items_ron(DEFAULT_ITEMS)
    }
}

impl VisualBindingIndex {
    pub fn from_json(text: &str) -> Result<Self, String> {
        serde_json::from_str(text).map_err(|e| format!("visual bindings: {e}"))
    }
}

impl ComponentPaletteEntry {
    pub fn load_map(text: &str) -> Result<BTreeMap<String, Self>, String> {
        #[derive(Deserialize)]
        struct File {
            #[serde(default)]
            components: BTreeMap<String, ComponentPaletteEntry>,
        }
        let file: File = serde_json::from_str(text).map_err(|e| format!("components: {e}"))?;
        Ok(file
            .components
            .into_iter()
            .map(|(id, mut entry)| {
                entry.id = id.clone();
                (id, entry)
            })
            .collect())
    }
}
