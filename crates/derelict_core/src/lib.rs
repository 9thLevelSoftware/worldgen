//! `derelict_core` — deterministic procedural generation of derelict
//! spacecraft for isometric tile-based games.
//!
//! Pure Rust, no engine dependencies. The public contract:
//! `generate_ship(seed, params, data)` is a pure function — identical inputs
//! and `GENERATOR_VERSION` produce byte-identical ships on any platform.

pub mod archetype;
pub mod authoring;
pub mod model;
pub mod pipeline;
pub mod rng;
pub mod role;
pub mod stages;
pub mod structural;
pub mod topology;

pub use archetype::GenData;
pub use model::{
    apply_diff, CauseOfLoss, Deck, DeckLayer, EntityKind, EntitySpec, FloorTile, GenParams,
    GridPos, ItemStack, RoomGraph, RoomNode, Ship, ShipMutationDiff, WallEdge,
};

/// Public worldgen contract version consumed by engine integrations.
///
/// The model's serialized field is kept as a legacy compatibility detail; all
/// new engine-facing entry points use this exported contract version.
pub const GENERATOR_VERSION: u32 = 3;
pub use authoring::{
    apply_module_overrides, compile_authored, AuthorPalettes, AuthoredHazards, AuthoredProp,
    BuilderKitCatalog, GoldenArea, LinkZone, ModuleOverrides, RoomVars, TopologyDto,
};
pub use pipeline::{generate_ship, generate_ship_timed, GenError, GenReport};
pub use role::Role;
pub use stages::hull::derive_site_seed;

#[cfg(test)]
mod generator_contract_tests {
    #[test]
    fn generator_version_is_v3() {
        assert_eq!(crate::GENERATOR_VERSION, 3);
    }
}
