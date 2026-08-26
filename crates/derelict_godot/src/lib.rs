//! GDExtension bridge: exposes `derelict_core` generation to Godot.
//!
//! All generation logic lives in `derelict_core`; this crate only marshals
//! data. Worker threads touch only plain `Send` Rust data — Godot objects
//! are constructed exclusively on the main thread during `poll_async`.

use godot::prelude::*;

mod async_gen;
mod convert;
pub mod export;
mod generator;

struct DerelictExtension;

#[gdextension]
unsafe impl ExtensionLibrary for DerelictExtension {}
