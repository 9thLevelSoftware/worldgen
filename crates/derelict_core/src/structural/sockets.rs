//! Socket contracts and kit catalogs — read directly from The Synaptic
//! Sea's JSON data (no dual authoring): per-module `*_contract.json` files
//! carry socket kinds/positions; kit catalog JSON maps module ids to Godot
//! wrapper scenes. Module selection is socket-kind-driven (port of
//! `ModularSocketCatalog.choose_module`), never hardcoded at emission sites.

use crate::structural::compile::{ModulePicker, VertexKind};
use crate::structural::plan::EdgeKind;
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::Path;

pub const ENCLOSURE_KINDS: [&str; 12] = [
    "floor_edge",
    "corridor_edge",
    "wall_base",
    "wall_end",
    "wall_edge",
    "portal_edge",
    "portal_center",
    "inner_corner_vertex",
    "outer_corner_vertex",
    "ceiling_edge",
    "floor_top",
    "ceiling_bottom",
];

#[derive(Clone, Debug, Deserialize)]
pub struct SocketDef {
    pub id: String,
    pub kind: String,
    #[serde(default)]
    pub position_m: [f32; 3],
    #[serde(default)]
    pub compatible_kinds: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ModuleContract {
    pub module_id: String,
    #[serde(default)]
    pub module_family: String,
    #[serde(default)]
    pub sockets: Vec<SocketDef>,
}

/// Per-module socket contracts for one kit.
#[derive(Clone, Debug, Default)]
pub struct SocketCatalog {
    pub modules: BTreeMap<String, ModuleContract>,
}

impl SocketCatalog {
    /// Load every `*_contract.json` in a kit's contract directory.
    pub fn load_dir(dir: &Path) -> std::io::Result<Self> {
        let mut modules = BTreeMap::new();
        let mut entries: Vec<_> = std::fs::read_dir(dir)?
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|n| n.ends_with("_contract.json"))
                    .unwrap_or(false)
            })
            .collect();
        entries.sort();
        for path in entries {
            let text = std::fs::read_to_string(&path)?;
            match serde_json::from_str::<ModuleContract>(&text) {
                Ok(c) if !c.sockets.is_empty() => {
                    modules.insert(c.module_id.clone(), c);
                }
                Ok(c) => {
                    // Some files nest everything under "asset".
                    #[derive(Deserialize)]
                    struct Nested {
                        asset: Option<ModuleContract>,
                    }
                    if let Ok(Nested { asset: Some(inner) }) = serde_json::from_str::<Nested>(&text)
                    {
                        if !inner.sockets.is_empty() {
                            modules.insert(inner.module_id.clone(), inner);
                            continue;
                        }
                    }
                    modules.insert(c.module_id.clone(), c);
                }
                Err(_) => continue,
            }
        }
        Ok(Self { modules })
    }

    pub fn has_all_kinds(&self, module_id: &str, required: &[&str]) -> bool {
        let Some(m) = self.modules.get(module_id) else {
            return false;
        };
        required
            .iter()
            .all(|k| m.sockets.iter().any(|s| s.kind == *k))
    }

    /// Socket-kind-driven module choice, ported from
    /// `ModularSocketCatalog.choose_module`: the preferred id wins if it
    /// satisfies every required kind; otherwise the first module (sorted by
    /// id) that does; otherwise the preferred id as a last resort.
    pub fn choose_module(&self, required: &[&str], preferred: &str) -> String {
        if !preferred.is_empty() && self.has_all_kinds(preferred, required) {
            return preferred.to_string();
        }
        for id in self.modules.keys() {
            if self.has_all_kinds(id, required) {
                return id.clone();
            }
        }
        preferred.to_string()
    }

    /// Reciprocal socket compatibility (kind equality, or each side listing
    /// the other's kind).
    pub fn sockets_compatible(a: &SocketDef, b: &SocketDef) -> bool {
        if !ENCLOSURE_KINDS.contains(&a.kind.as_str())
            || !ENCLOSURE_KINDS.contains(&b.kind.as_str())
        {
            return false;
        }
        if a.kind == b.kind {
            return true;
        }
        a.compatible_kinds.iter().any(|k| k == &b.kind)
            && b.compatible_kinds.iter().any(|k| k == &a.kind)
    }
}

/// Kit catalog: module id → Godot wrapper scene (what the game loader needs).
#[derive(Clone, Debug, Deserialize)]
pub struct KitCatalog {
    pub kit_id: String,
    #[serde(default)]
    pub modules: Vec<KitModule>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct KitModule {
    pub module_id: String,
    #[serde(default)]
    pub godot_wrapper_scene: String,
}

impl KitCatalog {
    pub fn load(path: &Path) -> std::io::Result<Self> {
        let text = std::fs::read_to_string(path)?;
        serde_json::from_str(&text).map_err(|e| std::io::Error::other(e.to_string()))
    }

    pub fn scene_of(&self, module_id: &str) -> Option<&str> {
        self.modules
            .iter()
            .find(|m| m.module_id == module_id)
            .map(|m| m.godot_wrapper_scene.as_str())
    }
}

/// A `ModulePicker` backed by real socket contracts — the compiler asks for
/// socket kinds, never names.
pub struct SocketModulePicker {
    pub catalog: SocketCatalog,
}

impl ModulePicker for SocketCatalog {
    fn floor(&self, role_is_connective: bool) -> String {
        let preferred = if role_is_connective {
            "corridor_floor_1x1"
        } else {
            "floor_1x1"
        };
        self.choose_module(&["floor_edge", "floor_top"], preferred)
    }
    fn ceiling(&self) -> String {
        self.choose_module(&["ceiling_edge", "ceiling_bottom"], "ceiling_cap_1x1")
    }
    fn wall(&self) -> String {
        self.choose_module(&["wall_base", "wall_end"], "wall_straight_1x1")
    }
    fn portal(&self, state: EdgeKind) -> String {
        let preferred = match state {
            EdgeKind::Locked => "doorway_frame_blocked_1x1",
            EdgeKind::Hatch => "bulkhead_portal_2x1",
            EdgeKind::Breach => return String::new(),
            _ => "doorway_frame_open_1x1",
        };
        self.choose_module(&["portal_edge", "wall_base"], preferred)
    }
    fn vertex(&self, kind: VertexKind) -> Option<String> {
        let (kinds, preferred): (&[&str], &str) = match kind {
            VertexKind::InnerCorner => (&["inner_corner_vertex"], "wall_inner_corner"),
            VertexKind::OuterCorner => (&["outer_corner_vertex"], "wall_outer_corner"),
            VertexKind::TJunction => (&["wall_face"], "wall_t_junction"),
        };
        if kind == VertexKind::TJunction && self.modules.contains_key("wall_t_junction") {
            return Some("wall_t_junction".into());
        }
        let chosen = self.choose_module(kinds, preferred);
        if self.modules.contains_key(&chosen) {
            Some(chosen)
        } else {
            None
        }
    }
}

impl ModulePicker for SocketModulePicker {
    fn floor(&self, role_is_connective: bool) -> String {
        self.catalog.floor(role_is_connective)
    }
    fn ceiling(&self) -> String {
        self.catalog.ceiling()
    }
    fn wall(&self) -> String {
        self.catalog.wall()
    }
    fn portal(&self, state: EdgeKind) -> String {
        self.catalog.portal(state)
    }
    fn vertex(&self, kind: VertexKind) -> Option<String> {
        self.catalog.vertex(kind)
    }
}
