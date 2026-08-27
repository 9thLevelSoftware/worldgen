//! Export a generated ship as The Synaptic Sea's `layout.json` (schema
//! 1.2.0, embedded structural_plan) plus a `gameplay_slice.json` — the exact
//! contract `GeneratedShipLoader.load_from_paths` consumes today. Field
//! shapes mirror the committed golden fixtures
//! (`data/procgen/golden/coherent_ship_001`).

use crate::archetype::ItemRegistry;
use crate::authoring::{
    compile_authored, AuthoredProp, GoldenArea, GoldenScope, InventoryMode, LinkZone,
};
use crate::model::{
    CauseOfLoss, EntityKind, EntitySpec, GridPos, ItemStack, RoomGraph, Ship, GENERATOR_VERSION,
    INTACT_MAX,
};
use crate::role::Role;
use crate::stages::furnish::{implied_access_entities, interior_zones};
use crate::structural::compile::{DefaultModulePicker, ModulePicker};
use crate::structural::plan::{
    edge_key, Cell, DamageVariant, Dir, EdgeRecord, FloorPlacement, RoomId, StructuralPlan, NO_ROOM,
};
use crate::structural::project::project_to_raster;
use crate::structural::validate::{validate, ValidationPolicy};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// Stable, human-readable room id string ("airlock_01" style).
pub fn room_name(role: Role, id: RoomId) -> String {
    format!("{}_{:02}", role.name(), id)
}

/// generate_ship export names: `"{role}_{id:02}"`.
pub fn default_room_names(ship: &Ship) -> BTreeMap<RoomId, String> {
    ship.topology
        .rooms
        .iter()
        .map(|r| (r.id, room_name(r.role, r.id)))
        .collect()
}

fn name_of_id(id: RoomId, names: &BTreeMap<RoomId, String>) -> String {
    if id == NO_ROOM {
        String::new()
    } else {
        names.get(&id).cloned().unwrap_or_default()
    }
}

fn cell2(c: Cell) -> Value {
    json!([c.x, c.y])
}

fn cell3(c: Cell) -> Value {
    json!([c.x, c.y, c.deck])
}

fn pos(p: [f32; 3]) -> Value {
    json!([p[0], p[1], p[2]])
}

fn variant_name(v: DamageVariant) -> &'static str {
    match v {
        DamageVariant::Intact => "intact",
        DamageVariant::Damaged => "damaged",
        DamageVariant::Breached => "breached",
    }
}

/// `structural_plan` object shared by layout export and the authoring preview.
pub fn structural_plan_to_json(
    plan: &StructuralPlan,
    name_of: &impl Fn(RoomId) -> String,
) -> Value {
    let edge_json = |e: &EdgeRecord, with_placement_id: bool| -> Value {
        let mut m = Map::new();
        m.insert("id".into(), json!(format!("edge:{}", e.edge_key)));
        m.insert("key".into(), json!(e.edge_key));
        m.insert("edge_key".into(), json!(e.edge_key));
        m.insert("deck".into(), json!(e.cell.deck));
        m.insert("cell".into(), cell2(e.cell));
        m.insert("direction".into(), json!(e.direction.name()));
        m.insert(
            "opposite_direction".into(),
            json!(e.direction.opposite().name()),
        );
        m.insert(
            "source_cells".into(),
            json!([cell3(e.source_cells[0]), cell3(e.source_cells[1])]),
        );
        m.insert(
            "room_ids".into(),
            json!([name_of(e.room_ids.0), name_of(e.room_ids.1)]),
        );
        m.insert("owner_room".into(), json!(name_of(e.room_ids.0)));
        m.insert("other_room".into(), json!(name_of(e.room_ids.1)));
        m.insert("kind".into(), json!(e.kind.name()));
        m.insert("state".into(), json!(e.kind.name()));
        m.insert("module_id".into(), json!(e.module_id));
        m.insert("variant".into(), json!(variant_name(e.variant)));
        m.insert("position".into(), pos(e.position));
        m.insert("yaw_degrees".into(), json!(e.yaw_degrees as f32));
        m.insert("portal".into(), json!(e.portal));
        m.insert("exterior".into(), json!(e.exterior));
        m.insert("placement_required".into(), json!(e.wrapper_required));
        m.insert("wrapper_required".into(), json!(e.wrapper_required));
        if with_placement_id {
            m.insert("placement_id".into(), json!(format!("edge:{}", e.edge_key)));
        }
        m.insert("socket_bindings".into(), json!([]));
        Value::Object(m)
    };

    let occupancy: Map<String, Value> = plan
        .occupancy
        .iter()
        .map(|(k, rec)| {
            (
                k.clone(),
                json!({
                    "cell_key": k,
                    "deck": rec.cell.deck,
                    "cell": cell2(rec.cell),
                    "room_id": name_of(rec.room_id),
                    "room_ids": [name_of(rec.room_id)],
                    "position": pos(rec.cell.world_pos()),
                    "module_id": rec.module_id,
                    "variant": variant_name(rec.variant),
                    "decal": rec.decal,
                }),
            )
        })
        .collect();
    let edges: Map<String, Value> = plan
        .edges
        .iter()
        .map(|(k, e)| (k.clone(), edge_json(e, false)))
        .collect();
    let placements: Vec<Value> = plan.placements.iter().map(|e| edge_json(e, true)).collect();
    let flat_placement = |f: &FloorPlacement| {
        json!({
            "id": f.id,
            "placement_id": f.id,
            "module_id": f.module_id,
            "position": pos(f.position),
            "yaw_degrees": f.yaw_degrees as f32,
            "deck": f.cell.deck,
            "cell": cell2(f.cell),
            "cell_key": f.cell_key,
            "room_id": name_of(f.room_id),
            "room_ids": [name_of(f.room_id)],
            "variant": variant_name(f.variant),
            "socket_bindings": [],
        })
    };
    json!({
        "occupancy": occupancy,
        "edges": edges,
        "placements": placements,
        "floor_placements": plan.floor_placements.iter().map(flat_placement).collect::<Vec<_>>(),
        "ceiling_placements": plan.ceiling_placements.iter().map(flat_placement).collect::<Vec<_>>(),
        "socket_bindings": plan.socket_bindings.iter().map(|b| json!({
            "placement_id": b.placement_id,
            "socket_id": b.socket_id,
            "neighbor_placement_id": b.neighbor_placement_id,
            "neighbor_socket_id": b.neighbor_socket_id,
            "kind": b.kind,
        })).collect::<Vec<_>>(),
        "errors": plan.errors,
    })
}

pub struct ExportOptions {
    pub kit_id: String,
    pub biome_id: String,
    pub difficulty_id: String,
}

impl Default for ExportOptions {
    fn default() -> Self {
        Self {
            kit_id: "ship_structural_v0".into(),
            biome_id: String::new(),
            difficulty_id: String::new(),
        }
    }
}

pub fn to_layout_json(ship: &Ship, opts: &ExportOptions) -> Value {
    to_layout_json_named(ship, opts, &default_room_names(ship))
}

/// Same as [`to_layout_json`] with an explicit `RoomId →` name map.
/// generate_ship uses [`default_room_names`]; golden export uses `stable_id`.
pub fn to_layout_json_named(
    ship: &Ship,
    opts: &ExportOptions,
    names: &BTreeMap<RoomId, String>,
) -> Value {
    let name_of = |id: RoomId| name_of_id(id, names);
    let zones = interior_zones(&ship.topology, &ship.plan);

    // --- rooms --------------------------------------------------------------
    let rooms: Vec<Value> = ship
        .topology
        .rooms
        .iter()
        .map(|room| {
            let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
            for c in &room.cells {
                x0 = x0.min(c.x);
                y0 = y0.min(c.y);
                x1 = x1.max(c.x);
                y1 = y1.max(c.y);
            }
            let placements: Vec<Value> = room
                .cells
                .iter()
                .filter_map(|c| {
                    let rec = ship.plan.occupancy.get(&c.key())?;
                    Some(json!({
                        "name": format!("floor_cell_x{}_z{}", c.x, c.y),
                        "module": rec.module_id,
                        "world_position": pos(c.world_pos()),
                    }))
                })
                .collect();
            let z = zones.get(&room.id);
            json!({
                "id": name_of(room.id),
                "room_role": room.role.name(),
                "deck": room.deck,
                "cells": room.cells.iter().map(|c| cell2(*c)).collect::<Vec<_>>(),
                "footprint": [x1 - x0 + 1, y1 - y0 + 1],
                "structural_placements": placements,
                "interior_zones": {
                    "reserved_cells": z.map(|z| z.reserved_cells.iter().map(|c| cell2(*c)).collect::<Vec<_>>()).unwrap_or_default(),
                    "wall_slots": z.map(|z| z.wall_slots.iter().map(|c| cell2(*c)).collect::<Vec<_>>()).unwrap_or_default(),
                    "center_slots": z.map(|z| z.center_slots.iter().map(|c| cell2(*c)).collect::<Vec<_>>()).unwrap_or_default(),
                },
            })
        })
        .collect();

    // --- portals + room links (interior only; exterior doors live as plan
    // edges, matching how the game's own serializer treats hull boundaries).
    let mut portals: Vec<Value> = Vec::new();
    let mut room_links: Vec<Value> = Vec::new();
    for p in &ship.topology.portals {
        if p.exterior || p.to_room == NO_ROOM {
            continue;
        }
        let Some(dir) = Dir::between(p.from_cell, p.to_cell) else {
            continue;
        };
        let key = edge_key(p.from_cell, dir);
        let module = ship
            .plan
            .edges
            .get(&key)
            .map(|e| e.module_id.clone())
            .unwrap_or_default();
        let id = format!("{}_to_{}", name_of(p.from_room), name_of(p.to_room));
        portals.push(json!({
            "id": id,
            "from_room": name_of(p.from_room),
            "to_room": name_of(p.to_room),
            "from_cell": cell2(p.from_cell),
            "to_cell": cell2(p.to_cell),
            "state": p.state.name(),
            "module_id": module,
            "edge_key": key,
            "deck": p.from_cell.deck,
            "direction": dir.name(),
            "opposite_direction": dir.opposite().name(),
            "required": true,
        }));
        room_links.push(json!({
            "id": id,
            "from_room": name_of(p.from_room),
            "to_room": name_of(p.to_room),
            "from_cell": cell3(p.from_cell),
            "to_cell": cell3(p.to_cell),
            "module_id": module,
        }));
    }

    let verticals: Vec<Value> = ship
        .topology
        .verticals
        .iter()
        .map(|v| {
            json!({
                "id": format!("{}_to_{}", name_of(v.from_room), name_of(v.to_room)),
                "type": "ladder",
                "module_id": "",
                "from_room": name_of(v.from_room),
                "to_room": name_of(v.to_room),
                "from_cell": cell3(v.from_cell),
                "to_cell": cell3(v.to_cell),
            })
        })
        .collect();

    let critical_path: Vec<Value> = ship
        .critical_path
        .iter()
        .map(|id| json!(name_of(*id)))
        .collect();

    let structural_plan = structural_plan_to_json(&ship.plan, &name_of);

    json!({
        "schema_version": "1.2.0",
        "document_kind": "ship_layout",
        "program_id": format!("worldgen-{}-{}", ship.archetype_id, ship.seed),
        "generator": {
            "name": "worldgen",
            "generator_version": ship.generator_version,
            "seed": ship.seed,
            "archetype_id": ship.archetype_id,
            "template_id": ship.template_id,
            "intactness_bp": ship.intactness,
            "cause_of_loss": format!("{:?}", ship.cause_of_loss),
            "fractured": ship.fractured,
        },
        "cell_size": 4.0,
        "kit_id": opts.kit_id,
        "biome_id": opts.biome_id,
        "difficulty_id": opts.difficulty_id,
        "hazard_source": "runtime",
        "rooms": rooms,
        "portals": portals,
        "room_links": room_links,
        "vertical_connections": verticals,
        "critical_path": critical_path,
        "prototype": {
            "start_room": name_of(ship.entry_room),
            "goal_room": name_of(ship.goal_room),
        },
        "landmarks": [],
        "encounters": [],
        "blocked_links": [],
        "fire_zones": link_zones_json(&ship.hazard_overlay.fire_zones),
        "arc_zones": link_zones_json(&ship.hazard_overlay.arc_zones),
        "breach_zones": link_zones_json(&ship.hazard_overlay.breach_zones),
        "radiation_zones": link_zones_json(&ship.hazard_overlay.radiation_zones),
        "structural_plan": structural_plan,
    })
}

/// Companion gameplay slice (schema 1.1.0): loot containers from the ship's
/// container entities, objectives from the goal room.
pub fn to_gameplay_slice_json(ship: &Ship) -> Value {
    to_gameplay_slice_json_named(ship, &default_room_names(ship))
}

/// Same as [`to_gameplay_slice_json`] with an explicit `RoomId →` name map.
pub fn to_gameplay_slice_json_named(ship: &Ship, names: &BTreeMap<RoomId, String>) -> Value {
    let name_of = |id: RoomId| name_of_id(id, names);
    let room_at = |deck: u8, x: i32, y: i32| -> Option<RoomId> {
        ship.topology
            .rooms
            .iter()
            .find(|r| {
                r.cells
                    .iter()
                    .any(|c| c.deck == deck && c.x == x && c.y == y)
            })
            .map(|r| r.id)
    };

    let loot_containers: Vec<Value> = ship
        .entities
        .iter()
        .filter(|e| e.kind == EntityKind::Container && !e.tags.iter().any(|t| t == "debris_field"))
        .filter_map(|e| {
            let room = room_at(e.pos.deck, e.pos.x, e.pos.y)?;
            let mut row = json!({
                "id": format!("container_{}", e.id),
                "kind": e.proto,
                "room_id": name_of(room),
                "approach_cell": [e.pos.x, e.pos.y, e.pos.deck],
                "loot_table": "worldgen_seeded",
            });
            overlay_authored_container(&mut row, e);
            Some(row)
        })
        .collect();

    let critical_path: Vec<Value> = ship
        .critical_path
        .iter()
        .map(|id| json!(name_of(*id)))
        .collect();
    // Objective 1: reach the goal room (anchored to one of its floor cells).
    let mut objectives: Vec<Value> = Vec::new();
    if let Some(goal) = ship.topology.rooms.iter().find(|r| r.id == ship.goal_room) {
        if let Some(cell) = goal.cells.first() {
            objectives.push(json!({
                "id": format!("{}:reach_goal", name_of(goal.id)),
                "sequence": 1,
                "type": "reach_room",
                "kind": "single",
                "room_id": name_of(goal.id),
                "room_role": goal.role.name(),
                "semantic": "goal_room",
                "cell": [cell.x, cell.y, cell.deck],
                "approach_cell": [cell.x, cell.y, cell.deck],
                "approach_distance_cells": 1,
                "interactable": false,
            }));
        }
    }
    json!({
        "schema_version": "1.1.0",
        "document_kind": "ship_gameplay_slice",
        "program_id": format!("worldgen-{}-{}", ship.archetype_id, ship.seed),
        "start_room": name_of(ship.entry_room),
        "goal_room": name_of(ship.goal_room),
        "critical_path": critical_path,
        "fire_zones": link_zones_json(&ship.hazard_overlay.fire_zones),
        "objectives": objectives,
        "loot_containers": loot_containers,
        "summary": format!(
            "worldgen {} seed {} intactness {:.2} ({:?})",
            ship.archetype_id,
            ship.seed,
            ship.intactness as f32 / 10_000.0,
            ship.cause_of_loss
        ),
    })
}

/// Playable documents produced from a golden area.
#[derive(Clone, Debug)]
pub struct PlayableExport {
    pub layout: Value,
    pub gameplay_slice: Value,
}

/// Compile + validate a golden area, synthesize a `Ship`, and reuse the
/// existing serializers with `stable_id` room names. Fail-closed.
pub fn layout_from_golden(golden: &GoldenArea) -> Result<PlayableExport, String> {
    layout_from_golden_with_picker(golden, &DefaultModulePicker, None)
}

/// Kit-aware export entry point. The caller supplies the exact picker and
/// floor allowlist used for preview/validation so generated runtime documents
/// cannot silently fall back to a different structural kit.
pub fn layout_from_golden_with_picker(
    golden: &GoldenArea,
    picker: &dyn ModulePicker,
    allowed_floor_modules: Option<Vec<String>>,
) -> Result<PlayableExport, String> {
    let topology = golden.to_topology()?;
    let (plan, _stale) = compile_authored(&topology, picker, &golden.module_overrides);

    let (entry_sid, goal_sid) = golden.resolved_entry_goal()?;
    let entry_room = resolve_stable_id(golden, &entry_sid)?;
    let goal_room = resolve_stable_id(golden, &goal_sid)?;
    if topology.rooms.iter().all(|r| r.id != entry_room) {
        return Err(format!("unresolved entry_room '{entry_sid}'"));
    }
    if topology.rooms.iter().all(|r| r.id != goal_room) {
        return Err(format!("unresolved goal_room '{goal_sid}'"));
    }

    let critical_path = if golden.scope == GoldenScope::Room || entry_room == goal_room {
        vec![entry_room]
    } else {
        derelict_bfs(&topology, entry_room, goal_room).ok_or_else(|| {
            format!("CriticalPathBroken: no BFS path from '{entry_sid}' to '{goal_sid}'")
        })?
    };
    let mut policy = match golden.scope {
        GoldenScope::Room | GoldenScope::Area => ValidationPolicy::pre_damage(Vec::new()),
        GoldenScope::Derelict => ValidationPolicy::pre_damage(critical_path.clone()),
    };
    policy.allowed_floor_modules = allowed_floor_modules;
    if let Err(issues) = validate(&plan, &topology, &policy) {
        return Err(issues
            .iter()
            .map(ToString::to_string)
            .collect::<Vec<_>>()
            .join("\n"));
    }

    let (mut entities, next_id) = implied_access_entities(&topology, &plan, 1);
    let items = offline_items();
    entities.extend(
        golden
            .props
            .iter()
            .enumerate()
            .map(|(i, prop)| prop_to_entity(prop, next_id + i as u32, &items)),
    );

    let decks = project_to_raster(&topology, &plan)
        .into_iter()
        .map(|layer| crate::model::Deck { layer })
        .collect();

    let ship = Ship {
        generator_version: GENERATOR_VERSION,
        seed: 0,
        archetype_id: "golden".into(),
        template_id: golden.id.clone(),
        intactness: INTACT_MAX,
        cause_of_loss: CauseOfLoss::Unknown,
        topology,
        plan,
        entry_room,
        goal_room,
        critical_path,
        decks,
        room_graph: RoomGraph::default(),
        entities,
        damage_events: Vec::new(),
        fractured: false,
        fragments: Vec::new(),
        hazard_overlay: Default::default(),
    };

    let names = golden.room_stable_ids();
    let kit_id = if golden.kit_id.is_empty() {
        ExportOptions::default().kit_id
    } else {
        golden.kit_id.clone()
    };
    let opts = ExportOptions {
        kit_id,
        ..Default::default()
    };
    let mut layout = to_layout_json_named(&ship, &opts, &names);
    let mut gameplay_slice = to_gameplay_slice_json_named(&ship, &names);
    overlay_authored(&mut layout, &mut gameplay_slice, golden)?;
    Ok(PlayableExport {
        layout,
        gameplay_slice,
    })
}

fn resolve_stable_id(golden: &GoldenArea, stable_id: &str) -> Result<RoomId, String> {
    golden
        .topology
        .rooms
        .iter()
        .find(|r| r.stable_id == stable_id)
        .map(|r| r.id)
        .ok_or_else(|| format!("unresolved room stable_id '{stable_id}'"))
}

fn derelict_bfs(
    topology: &crate::structural::plan::Topology,
    entry: RoomId,
    goal: RoomId,
) -> Option<Vec<RoomId>> {
    let mut links = Vec::new();
    for p in &topology.portals {
        if p.from_room != NO_ROOM && p.to_room != NO_ROOM {
            links.push((p.from_room, p.to_room));
        }
    }
    for v in &topology.verticals {
        if v.from_room != NO_ROOM && v.to_room != NO_ROOM {
            links.push((v.from_room, v.to_room));
        }
    }
    crate::topology::room_path(entry, goal, &links)
}

fn offline_items() -> ItemRegistry {
    ron::from_str(include_str!("../../assets/items.ron"))
        .unwrap_or(ItemRegistry { items: Vec::new() })
}

fn prop_to_entity(prop: &AuthoredProp, id: u32, items: &ItemRegistry) -> EntitySpec {
    let deck = u8::try_from(prop.cell[2]).unwrap_or(0);
    let inventory = match prop.inventory_mode {
        InventoryMode::Explicit => prop
            .inventory
            .iter()
            .filter_map(|s| {
                items.id_of(&s.item_id).map(|item_id| ItemStack {
                    item_id,
                    qty: s.qty,
                })
            })
            .collect(),
        InventoryMode::LootTable | InventoryMode::Empty => Vec::new(),
    };
    EntitySpec {
        id,
        kind: prop.kind,
        proto: prop.proto.clone(),
        pos: GridPos::new(prop.cell[0], prop.cell[1], deck),
        rotation: prop.rotation,
        locked: prop.locked,
        open: false,
        inventory,
        tags: Vec::new(),
    }
}

fn overlay_authored(
    layout: &mut Value,
    slice: &mut Value,
    golden: &GoldenArea,
) -> Result<(), String> {
    if let Some(gen) = layout.get_mut("generator").and_then(Value::as_object_mut) {
        gen.insert("name".into(), json!("derelict_builder"));
    }
    if let Some(obj) = layout.as_object_mut() {
        obj.insert("hazard_source".into(), json!("authored"));
        obj.insert(
            "fire_zones".into(),
            link_zones_json(&golden.hazards.fire_zones),
        );
        obj.insert(
            "arc_zones".into(),
            link_zones_json(&golden.hazards.arc_zones),
        );
        obj.insert(
            "breach_zones".into(),
            link_zones_json(&golden.hazards.breach_zones),
        );
        obj.insert(
            "radiation_zones".into(),
            link_zones_json(&golden.hazards.radiation_zones),
        );
    }

    let mut vars_by_name: BTreeMap<&str, &crate::authoring::RoomVars> = BTreeMap::new();
    let mut vented: Vec<Value> = Vec::new();
    let mut seen_cid: BTreeSet<&str> = BTreeSet::new();
    for room in &golden.topology.rooms {
        if let Some(vars) = golden
            .room_vars
            .get(&room.stable_id)
            .or_else(|| golden.room_vars.get(&room.id.to_string()))
        {
            vars_by_name.insert(room.stable_id.as_str(), vars);
            if vars.vented {
                if let Some(cid) = compartment_for_role(&room.role) {
                    if seen_cid.insert(cid) {
                        vented.push(json!(cid));
                    }
                }
            }
        }
    }
    if let Some(obj) = slice.as_object_mut() {
        obj.insert(
            "fire_zones".into(),
            link_zones_json(&golden.hazards.fire_zones),
        );
        obj.insert("vented_compartments".into(), Value::Array(vented));
    }
    if let Some(rooms) = layout.get_mut("rooms").and_then(Value::as_array_mut) {
        for room in rooms {
            let Some(id) = room.get("id").and_then(Value::as_str) else {
                continue;
            };
            let Some(vars) = vars_by_name.get(id) else {
                continue;
            };
            if let Some(obj) = room.as_object_mut() {
                obj.insert("depressurized".into(), json!(vars.depressurized));
                obj.insert("atmosphere_bp".into(), json!(vars.oxygen_bp));
            }
        }
    }

    overlay_loot_contents(slice, golden)?;
    if let Some(obj) = slice.as_object_mut() {
        obj.insert("placed_props".into(), authored_placed_props(golden)?);
    }
    Ok(())
}

/// Export authored props as placement/visual identity.  Inventory interaction
/// remains represented by `loot_containers`; this projection deliberately does
/// not create a second loot authority for the runtime.
fn authored_placed_props(golden: &GoldenArea) -> Result<Value, String> {
    golden
        .props
        .iter()
        .map(|prop| {
            let room_id = room_stable_at(golden, prop.cell).ok_or_else(|| {
                format!(
                    "authored prop '{}' has no room ownership at cell {:?}",
                    prop.id, prop.cell
                )
            })?;
            let mut row = serde_json::Map::new();
            row.insert("id".into(), json!(format!("prop_{}", prop.id)));
            row.insert("kind".into(), json!(prop.kind));
            row.insert("proto".into(), json!(prop.proto));
            row.insert("visual_id".into(), json!(prop.visual_id));
            row.insert("room_id".into(), json!(room_id));
            row.insert("cell".into(), json!(prop.cell));
            row.insert("approach_cell".into(), json!(prop.cell));
            row.insert("rotation".into(), json!(prop.rotation));
            row.insert("facing".into(), json!(prop.facing));
            row.insert("locked".into(), json!(prop.locked));
            row.insert("inventory_mode".into(), json!(prop.inventory_mode));
            match prop.inventory_mode {
                InventoryMode::Explicit => {
                    row.insert("contents".into(), loot_contents_json(prop));
                    if let Some(table) = prop.loot_table.as_ref().filter(|t| !t.is_empty()) {
                        row.insert("loot_table".into(), json!(table));
                    }
                }
                InventoryMode::LootTable => {
                    if let Some(table) = prop.loot_table.as_ref().filter(|t| !t.is_empty()) {
                        row.insert("loot_table".into(), json!(table));
                    }
                }
                InventoryMode::Empty => {
                    row.insert("contents".into(), json!([]));
                }
            }
            Ok(Value::Object(row))
        })
        .collect::<Result<Vec<_>, String>>()
        .map(Value::Array)
}

/// Loader `COMPARTMENT_FOR_ROLE`. Unmapped roles stay visual-only.
fn compartment_for_role(role: &str) -> Option<&'static str> {
    match role {
        "bridge" | "cockpit" => Some("bridge"),
        "engineering" | "reactor" | "engine_bay" => Some("engineering"),
        "hydroponics" => Some("hydroponics"),
        "cargo" | "storage" => Some("cargo"),
        _ => None,
    }
}

fn link_zones_json(zones: &[LinkZone]) -> Value {
    Value::Array(zones.iter().map(link_zone_json).collect())
}

fn link_zone_json(z: &LinkZone) -> Value {
    json!({
        "id": z.id,
        "zone_id": z.id,
        "from_room": z.from_room,
        "to_room": z.to_room,
        "from_cell": z.from_cell,
        "to_cell": z.to_cell,
        "module_id": z.module_id,
        "kind": z.kind,
        "compartment_id": z.compartment_id,
        "rationale": z.rationale,
    })
}

fn overlay_loot_contents(slice: &mut Value, golden: &GoldenArea) -> Result<(), String> {
    if slice
        .get("loot_containers")
        .and_then(Value::as_array)
        .is_none()
    {
        if let Some(obj) = slice.as_object_mut() {
            obj.insert("loot_containers".into(), json!([]));
        }
    }
    let Some(containers) = slice
        .get_mut("loot_containers")
        .and_then(Value::as_array_mut)
    else {
        return Ok(());
    };

    for container in containers.iter_mut() {
        let Some(cell) = approach_cell_of(container) else {
            continue;
        };
        let Some(prop) = golden
            .props
            .iter()
            .find(|p| holds_loot(p.kind) && p.cell == cell)
        else {
            continue;
        };
        let Some(obj) = container.as_object_mut() else {
            continue;
        };
        apply_loot_overlay(obj, prop);
    }

    // Serializer only emits Containers (generate_ship hash-stable). ItemPiles
    // are appended here so playable goldens still carry authored loot.
    let mut extra: Vec<Value> = Vec::new();
    for prop in &golden.props {
        if prop.kind != EntityKind::ItemPile {
            continue;
        }
        if containers
            .iter()
            .any(|c| approach_cell_of(c) == Some(prop.cell))
        {
            continue;
        }
        let Some(room_id) = room_stable_at(golden, prop.cell) else {
            continue;
        };
        let mut row = itempile_loot_row(prop, &room_id);
        if let Some(obj) = row.as_object_mut() {
            apply_loot_overlay(obj, prop);
        }
        extra.push(row);
    }
    containers.extend(extra);

    for prop in &golden.props {
        if !holds_loot(prop.kind) {
            continue;
        }
        if !containers
            .iter()
            .any(|c| approach_cell_of(c) == Some(prop.cell))
        {
            return Err(format!(
                "explicit {:?} '{}' has no matching loot_containers row (cell {:?})",
                prop.kind, prop.proto, prop.cell
            ));
        }
    }
    Ok(())
}

fn holds_loot(kind: EntityKind) -> bool {
    matches!(kind, EntityKind::Container | EntityKind::ItemPile)
}

fn approach_cell_of(v: &Value) -> Option<[i32; 3]> {
    let a = v.get("approach_cell")?.as_array()?;
    if a.len() < 3 {
        return None;
    }
    Some([
        a[0].as_i64()? as i32,
        a[1].as_i64()? as i32,
        a[2].as_i64()? as i32,
    ])
}

fn room_stable_at(golden: &GoldenArea, cell: [i32; 3]) -> Option<String> {
    let deck = u8::try_from(cell[2]).ok()?;
    golden
        .topology
        .rooms
        .iter()
        .find(|r| r.deck == deck && r.cells.iter().any(|c| c[0] == cell[0] && c[1] == cell[1]))
        .map(|r| r.stable_id.clone())
}

fn overlay_authored_container(row: &mut Value, e: &EntitySpec) {
    if !e.tags.iter().any(|t| t == "authored_skip_loot") {
        return;
    }
    let Some(obj) = row.as_object_mut() else {
        return;
    };
    if e.tags.iter().any(|t| t == "authored_empty") {
        obj.insert("loot_table".into(), json!("authored_empty"));
        obj.insert("contents".into(), json!([]));
        return;
    }
    if let Some(table) = e
        .tags
        .iter()
        .find_map(|t| t.strip_prefix("authored_loot_table:"))
        .filter(|t| !t.is_empty())
    {
        obj.insert("loot_table".into(), json!(table));
        return;
    }
    let contents: Vec<Value> = e
        .tags
        .iter()
        .filter_map(|t| {
            let rest = t.strip_prefix("content:")?;
            let (item_id, qty) = rest.split_once(':')?;
            let qty: u16 = qty.parse().ok()?;
            Some(json!({ "item_id": item_id, "qty": qty }))
        })
        .collect();
    obj.insert("loot_table".into(), json!("authored_explicit"));
    obj.insert("contents".into(), Value::Array(contents));
}

fn apply_loot_overlay(obj: &mut Map<String, Value>, prop: &AuthoredProp) {
    match prop.inventory_mode {
        InventoryMode::Explicit => {
            obj.insert("contents".into(), loot_contents_json(prop));
            obj.insert("loot_table".into(), json!(explicit_table(prop)));
        }
        InventoryMode::LootTable => {
            if let Some(table) = prop.loot_table.as_ref().filter(|t| !t.is_empty()) {
                obj.insert("loot_table".into(), json!(table));
            }
        }
        InventoryMode::Empty => {
            // Do not leave the serializer's worldgen_seeded stamp on an
            // authored-empty container — the loader would roll loot.
            obj.insert("loot_table".into(), json!("authored_empty"));
            obj.insert("contents".into(), json!([]));
        }
    }
}

fn explicit_table(prop: &AuthoredProp) -> &str {
    prop.loot_table
        .as_deref()
        .filter(|t| !t.is_empty())
        .unwrap_or("authored_explicit")
}

fn loot_contents_json(prop: &AuthoredProp) -> Value {
    Value::Array(
        prop.inventory
            .iter()
            .map(|s| json!({ "item_id": s.item_id, "qty": s.qty }))
            .collect(),
    )
}

fn itempile_loot_row(prop: &AuthoredProp, room_id: &str) -> Value {
    json!({
        "id": format!("itempile_{}", prop.id),
        "kind": prop.proto,
        "room_id": room_id,
        "approach_cell": prop.cell,
        "loot_table": explicit_table(prop),
        "contents": loot_contents_json(prop),
    })
}
