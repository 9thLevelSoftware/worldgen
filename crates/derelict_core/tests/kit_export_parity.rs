//! Kit-aware golden-area export contracts.
//!
//! These tests intentionally exercise the picker and validation policy through
//! the public export boundary.  A custom kit must not silently fall back to
//! the default floor allowlist, and room variables keyed by stable room ids
//! must have the same export semantics as legacy numeric keys.

use derelict_core::authoring::{GoldenArea, RoomVars};
use derelict_core::structural::compile::{DefaultModulePicker, ModulePicker, VertexKind};
use derelict_core::structural::export::{layout_from_golden, layout_from_golden_with_picker};
use derelict_core::structural::plan::EdgeKind;
use serde_json::Value;

const SAMPLE: &str = include_str!("../assets/golden_areas/airlock_2x2.json");
const CUSTOM_FLOOR: &str = "custom_airlock_floor_1x1";

struct CustomFloorPicker {
    default: DefaultModulePicker,
}

impl CustomFloorPicker {
    fn new() -> Self {
        Self {
            default: DefaultModulePicker,
        }
    }
}

impl ModulePicker for CustomFloorPicker {
    fn floor(&self, _role_is_connective: bool) -> String {
        CUSTOM_FLOOR.into()
    }

    fn ceiling(&self) -> String {
        self.default.ceiling()
    }

    fn wall(&self) -> String {
        self.default.wall()
    }

    fn portal(&self, state: EdgeKind) -> String {
        self.default.portal(state)
    }

    fn vertex(&self, kind: VertexKind) -> Option<String> {
        self.default.vertex(kind)
    }
}

fn sample() -> GoldenArea {
    serde_json::from_str(SAMPLE).expect("sample golden area json")
}

#[test]
fn custom_kit_floor_requires_matching_allowlist() {
    let mut golden = sample();
    // The fixture carries two explicit default floor overrides.  Remove those
    // authored overrides so this contract isolates picker/allowlist parity.
    golden.module_overrides.floors.clear();
    let picker = CustomFloorPicker::new();

    let err = layout_from_golden_with_picker(&golden, &picker, None)
        .expect_err("custom floor must not pass the default floor allowlist");
    assert!(
        err.contains("FloorBadModule"),
        "unexpected validation error: {err}"
    );

    let docs =
        layout_from_golden_with_picker(&golden, &picker, Some(vec![CUSTOM_FLOOR.to_string()]))
            .expect("matching custom floor allowlist should export");
    let placements = docs.layout["structural_plan"]["floor_placements"]
        .as_array()
        .expect("floor placements array");
    assert!(!placements.is_empty());
    assert!(placements
        .iter()
        .all(|placement| { placement["module_id"].as_str() == Some(CUSTOM_FLOOR) }));
}

#[test]
fn compatibility_export_rejects_unresolved_non_default_kit() {
    let mut golden = sample();
    golden.kit_id = "missing_runtime_kit".into();
    let err =
        layout_from_golden(&golden).expect_err("default export must not stamp an unresolved kit");
    assert!(
        err.contains("layout_from_golden_with_picker"),
        "unexpected error: {err}"
    );
}

#[test]
fn stable_room_var_key_controls_atmosphere_and_numeric_key_remains_compatible() {
    let legacy = sample();
    let legacy_docs = layout_from_golden_with_picker(&legacy, &DefaultModulePicker, None)
        .expect("legacy numeric room var should export");
    assert_eq!(legacy_docs.layout["rooms"][0]["atmosphere_bp"], 8500);

    let mut stable = sample();
    stable.room_vars.remove("1");
    stable.room_vars.insert(
        "airlock_01".into(),
        RoomVars {
            oxygen_bp: 6100,
            depressurized: false,
            vented: false,
            radiation_bp: 0,
            temperature_c: 18,
            notes: String::new(),
        },
    );
    let stable_docs = layout_from_golden_with_picker(&stable, &DefaultModulePicker, None)
        .expect("stable room-id room var should export");
    assert_eq!(
        stable_docs.layout["rooms"][0]["id"],
        Value::String("airlock_01".into())
    );
    assert_eq!(stable_docs.layout["rooms"][0]["atmosphere_bp"], 6100);
}
