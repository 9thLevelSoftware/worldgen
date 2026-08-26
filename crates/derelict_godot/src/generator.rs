//! The `DerelictGenerator` Godot class — the entire scripting API surface.

use crate::async_gen::{AsyncGen, GenResult};
use crate::convert::{gen_params_from_dict, ship_to_dictionary};
use derelict_core::GenData;
use godot::builtin::{GString, VarDictionary, Variant};
use godot::classes::RefCounted;
use godot::meta::ToGodot;
use godot::obj::Base;
use godot::prelude::{godot_api, GodotClass};

#[derive(GodotClass)]
#[class(init, base=RefCounted)]
pub struct DerelictGenerator {
    base: Base<RefCounted>,
    #[init(val = None)]
    data: Option<GenData>,
    #[init(val = AsyncGen::default())]
    async_gen: AsyncGen,
}

impl DerelictGenerator {
    fn data(&mut self) -> &GenData {
        if self.data.is_none() {
            self.data = Some(GenData::default_bundle().expect("embedded content data is valid"));
        }
        self.data.as_ref().unwrap()
    }
}

#[godot_api]
impl DerelictGenerator {
    /// Synchronous generation. `params` keys: archetype_id (String),
    /// intactness_override (int bp 0..=10000, optional), cause_override
    /// (String, optional), loot_richness (int bp, optional).
    #[func]
    fn generate(&mut self, seed: i64, params: VarDictionary) -> VarDictionary {
        let p = gen_params_from_dict(&params);
        let data = self.data().clone();
        match derelict_core::generate_ship(seed as u64, &p, &data) {
            Ok(ship) => ship_to_dictionary(&ship),
            Err(e) => {
                let mut d = VarDictionary::new();
                d.set("error", e.to_string());
                d
            }
        }
    }


    /// Start background generation; returns a request id for poll_async.
    #[func]
    fn generate_async(&mut self, seed: i64, params: VarDictionary) -> i64 {
        let p = gen_params_from_dict(&params);
        let data = self.data().clone();
        self.async_gen.start(seed as u64, p, data)
    }

    /// NIL while running; a ship VarDictionary (or {"error": ...}) exactly once
    /// when finished.
    #[func]
    fn poll_async(&mut self, request_id: i64) -> Variant {
        match self.async_gen.poll(request_id) {
            None => Variant::nil(),
            Some(GenResult::Ok(ship)) => ship_to_dictionary(&ship).to_variant(),
            Some(GenResult::Err(e)) => {
                let mut d = VarDictionary::new();
                d.set("error", e);
                d.to_variant()
            }
        }
    }

    /// Deterministic site seed from world seed + world tile position.
    /// Discovery-order independent — safe for co-op derivation on any peer.
    #[func]
    fn derive_site_seed(&self, world_seed: i64, world_x: i64, world_y: i64) -> i64 {
        derelict_core::derive_site_seed(world_seed as u64, world_x, world_y) as i64
    }

    /// Item id -> name catalog (placeholder registry until the real game's
    /// item system takes over).
    #[func]
    fn item_catalog(&mut self) -> VarDictionary {
        let mut d = VarDictionary::new();
        for item in &self.data().items.items {
            d.set(item.id as i64, item.name.as_str());
        }
        d
    }

    /// List of available archetype ids.
    #[func]
    fn archetypes(&mut self) -> godot::builtin::PackedStringArray {
        self.data().archetypes.keys().map(|k| k.into()).collect()
    }

    #[func]
    fn generator_version(&self) -> i64 {
        derelict_core::GENERATOR_VERSION as i64
    }

    /// Generate a ship and return The Synaptic Sea layout.json document as a
    /// JSON string (schema 1.2.0, embedded structural_plan). Empty string on
    /// failure (details pushed to the Godot error log).
    #[func]
    fn export_layout_json(&mut self, seed: i64, params: VarDictionary, kit_id: GString) -> GString {
        use derelict_core::structural::export::{to_layout_json, ExportOptions};
        let p = gen_params_from_dict(&params);
        let data = self.data().clone();
        match derelict_core::generate_ship(seed as u64, &p, &data) {
            Ok(ship) => {
                let opts = ExportOptions {
                    kit_id: kit_id.to_string(),
                    ..Default::default()
                };
                GString::from(
                    serde_json::to_string_pretty(&to_layout_json(&ship, &opts))
                        .unwrap_or_default()
                        .as_str(),
                )
            }
            Err(e) => {
                godot::global::godot_error!("worldgen export failed: {e}");
                GString::new()
            }
        }
    }

    /// Companion gameplay_slice.json document for the same seed/params.
    #[func]
    fn export_gameplay_slice_json(&mut self, seed: i64, params: VarDictionary) -> GString {
        use derelict_core::structural::export::to_gameplay_slice_json;
        let p = gen_params_from_dict(&params);
        let data = self.data().clone();
        match derelict_core::generate_ship(seed as u64, &p, &data) {
            Ok(ship) => GString::from(
                serde_json::to_string_pretty(&to_gameplay_slice_json(&ship))
                    .unwrap_or_default()
                    .as_str(),
            ),
            Err(e) => {
                godot::global::godot_error!("worldgen export failed: {e}");
                GString::new()
            }
        }
    }
}
