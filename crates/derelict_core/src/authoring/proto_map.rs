//! Furnishing proto → visual binding id. Unmapped protos preview as CSG.

use std::collections::BTreeMap;
use std::sync::OnceLock;

const PROTO_VISUAL_MAP: &str = include_str!("../../assets/proto_visual_map.json");

static PROTO_VISUAL: OnceLock<Result<BTreeMap<String, String>, String>> = OnceLock::new();

fn cached() -> &'static Result<BTreeMap<String, String>, String> {
    PROTO_VISUAL.get_or_init(|| {
        serde_json::from_str(PROTO_VISUAL_MAP).map_err(|e| format!("proto_visual_map: {e}"))
    })
}

pub fn load_proto_visual_map() -> Result<BTreeMap<String, String>, String> {
    cached().clone()
}

/// `bunk` maps to `generic_locker` as a preview stand-in (no bunk GLB).
pub fn proto_visual(proto: &str) -> Option<String> {
    cached().as_ref().ok()?.get(proto).cloned()
}
