//! Room role vocabulary — ported from The Synaptic Sea's role system.
//!
//! Closed enum so hazard/comfort/connective classification is compile-time
//! exhaustive; authored data referencing unknown role strings is a hard
//! load-time error (resolved through the alias table first).

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug, Serialize, Deserialize)]
pub enum Role {
    Airlock,
    Dock,
    Corridor,
    MainSpine,
    Hub,
    Ramp,
    Elevator,
    Bridge,
    Engineering,
    Reactor,
    LifeSupport,
    Maintenance,
    Cargo,
    Hangar,
    Storage,
    Armory,
    Security,
    Medical,
    CrewQuarters,
    MessHall,
    Compartment,
}

impl Role {
    pub const ALL: [Role; 21] = [
        Role::Airlock,
        Role::Dock,
        Role::Corridor,
        Role::MainSpine,
        Role::Hub,
        Role::Ramp,
        Role::Elevator,
        Role::Bridge,
        Role::Engineering,
        Role::Reactor,
        Role::LifeSupport,
        Role::Maintenance,
        Role::Cargo,
        Role::Hangar,
        Role::Storage,
        Role::Armory,
        Role::Security,
        Role::Medical,
        Role::CrewQuarters,
        Role::MessHall,
        Role::Compartment,
    ];

    /// Connective roles are exempt from adjacency-compatibility rules and
    /// get corridor-style flooring.
    pub fn is_connective(self) -> bool {
        matches!(
            self,
            Role::Corridor
                | Role::MainSpine
                | Role::Hub
                | Role::Ramp
                | Role::Elevator
                | Role::Airlock
                | Role::Dock
        )
    }

    pub fn is_hazardous(self) -> bool {
        matches!(self, Role::Reactor | Role::Engineering)
    }

    pub fn is_crew_comfort(self) -> bool {
        matches!(
            self,
            Role::CrewQuarters | Role::Medical | Role::MessHall | Role::Bridge
        )
    }

    /// Resolve an authored role string (Synaptic Sea vocabulary + aliases).
    pub fn parse(s: &str) -> Option<Role> {
        Some(match s {
            "airlock" => Role::Airlock,
            "dock" => Role::Dock,
            "corridor" => Role::Corridor,
            "main_spine" => Role::MainSpine,
            "hub" => Role::Hub,
            "ramp" => Role::Ramp,
            "elevator" => Role::Elevator,
            "bridge" | "cockpit" => Role::Bridge,
            "engineering" | "engine_bay" => Role::Engineering,
            "reactor" => Role::Reactor,
            "life_support" => Role::LifeSupport,
            "maintenance" => Role::Maintenance,
            "cargo" | "compartment_cargo" | "bay" => Role::Cargo,
            "hangar" => Role::Hangar,
            "storage" | "tool_storage" => Role::Storage,
            "armory" => Role::Armory,
            "security" => Role::Security,
            "medical" | "medbay" => Role::Medical,
            "crew_quarters" | "quarters" => Role::CrewQuarters,
            "mess_hall" | "galley" => Role::MessHall,
            "compartment" => Role::Compartment,
            _ => return None,
        })
    }

    /// Canonical export name (Synaptic Sea layout.json vocabulary).
    pub fn name(self) -> &'static str {
        match self {
            Role::Airlock => "airlock",
            Role::Dock => "dock",
            Role::Corridor => "corridor",
            Role::MainSpine => "main_spine",
            Role::Hub => "hub",
            Role::Ramp => "ramp",
            Role::Elevator => "elevator",
            Role::Bridge => "bridge",
            Role::Engineering => "engineering",
            Role::Reactor => "reactor",
            Role::LifeSupport => "life_support",
            Role::Maintenance => "maintenance",
            Role::Cargo => "cargo",
            Role::Hangar => "hangar",
            Role::Storage => "storage",
            Role::Armory => "armory",
            Role::Security => "security",
            Role::Medical => "medical",
            Role::CrewQuarters => "crew_quarters",
            Role::MessHall => "mess_hall",
            Role::Compartment => "compartment",
        }
    }
}
