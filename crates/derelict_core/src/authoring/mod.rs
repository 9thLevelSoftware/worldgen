//! Golden-area DTO, Topology adapter, and post-compile module overrides.

mod dto;
mod overrides;

pub use dto::{
    AttachEdge, AuthoredHazards, AuthoredProp, AuthoredStack, GoldenArea, GoldenScope,
    InventoryMode, LinkZone, ModuleOverrides, PortalIntentDto, RoomSpecDto, RoomVars, StampMeta,
    TopologyDto, VerticalConnectionDto,
};
pub use overrides::{apply_module_overrides, compile_authored, StaleClass, StaleOverride};
