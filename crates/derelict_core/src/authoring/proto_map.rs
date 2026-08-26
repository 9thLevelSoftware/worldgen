//! Furnishing proto → visual binding id. Unmapped protos preview as CSG.

use std::collections::BTreeMap;

const PROTO_VISUAL_MAP: &str = include_str!("../../assets/proto_visual_map.json");

fn parse_proto_visual_map(text: &str) -> Result<BTreeMap<String, String>, String> {
    serde_json::from_str(text).map_err(|e| format!("proto_visual_map: {e}"))
}

pub fn load_proto_visual_map() -> Result<BTreeMap<String, String>, String> {
    parse_proto_visual_map(PROTO_VISUAL_MAP)
}

/// `bunk` maps to `generic_locker` as a preview stand-in (no bunk GLB).
pub fn proto_visual(proto: &str) -> Option<String> {
    load_proto_visual_map()
        .ok()
        .and_then(|m| m.get(proto).cloned())
}
