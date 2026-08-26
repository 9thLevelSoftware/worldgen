//! Golden-area DTO, Topology adapter, and post-compile module overrides.

mod dto;
mod overrides;
mod palettes;
mod proto_map;

pub use dto::{
    AttachEdge, AuthoredHazards, AuthoredProp, AuthoredStack, GoldenArea, GoldenScope,
    InventoryMode, LinkZone, ModuleOverrides, PortalIntentDto, RoomSpecDto, RoomVars, StampMeta,
    TopologyDto, VerticalConnectionDto,
};
pub use overrides::{apply_module_overrides, compile_authored, StaleClass, StaleOverride};
pub use palettes::{
    AuthorPalettes, BuilderKitCatalog, BuilderKitModule, ComponentPaletteEntry, GameplayPropEntry,
    ItemPaletteEntry, VisualBinding, VisualBindingIndex,
};
pub use proto_map::{load_proto_visual_map, proto_visual};
