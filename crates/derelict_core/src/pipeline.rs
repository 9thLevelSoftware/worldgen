//! Pipeline orchestration, v2: authored topology is the authority.
//!
//! hull → template select → [topology placement + residual fill + compile +
//! PRE-DAMAGE validation, bounded retries] → furnish → story → [damage +
//! recompile + POST-DAMAGE validation, bounded retries] → loot → raster
//! projection → Ship. Every failure is typed; there is no best-effort ship.

use crate::archetype::{GenData, ItemRegistry};
use crate::authoring::{compile_authored, AuthoredProp, InventoryMode, StaleClass};
use crate::model::*;
use crate::rng::{self, roll_range, weighted_choice};
use crate::stages::{damage, furnish, hull, loot, story};
use crate::structural::compile::DefaultModulePicker;
use crate::structural::plan::{EdgeKind, RoomId as PlanRoomId, StructuralPlan, Topology};
use crate::structural::project::project_to_raster;
use crate::structural::validate::{validate, ValidationPolicy, ValidationStage};
use crate::topology::{
    apply_golden_stamps, place_topology, remap_stamp_for_drift, residual_fill, RoleParams,
    TemplateDef,
};
use std::collections::BTreeMap;
use std::time::Instant;

/// Bounded retry budgets (attempt index folds into RNG stream sub-keys; the
/// master seed is never mutated).
const TOPOLOGY_ATTEMPTS: u64 = 4;
const DAMAGE_ATTEMPTS: u64 = 3;

#[derive(Debug)]
pub enum GenError {
    UnknownArchetype(String),
    NoCompatibleTemplate {
        archetype: String,
        deck_count: u8,
    },
    TopologyFailed(String),
    StructuralCompileFailed(Vec<String>),
    StructuralValidationFailed {
        stage: ValidationStage,
        issues: Vec<String>,
    },
    RetriesExhausted {
        attempts: u64,
        last: Box<GenError>,
    },
}

impl std::fmt::Display for GenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GenError::UnknownArchetype(id) => write!(f, "unknown archetype '{id}'"),
            GenError::NoCompatibleTemplate {
                archetype,
                deck_count,
            } => write!(
                f,
                "no topology template satisfies '{archetype}' guarantees at {deck_count} deck(s)"
            ),
            GenError::TopologyFailed(e) => write!(f, "topology placement failed: {e}"),
            GenError::StructuralCompileFailed(errs) => {
                write!(f, "structural compile failed: {}", errs.join("; "))
            }
            GenError::StructuralValidationFailed { stage, issues } => write!(
                f,
                "structural validation failed ({stage:?}): {}",
                issues.join("; ")
            ),
            GenError::RetriesExhausted { attempts, last } => {
                write!(
                    f,
                    "generation failed after {attempts} attempts; last error: {last}"
                )
            }
        }
    }
}

impl std::error::Error for GenError {}

/// Per-stage wall-clock timings (diagnostic only; never feeds generation).
pub struct GenReport {
    pub ship: Ship,
    pub stage_micros: Vec<(&'static str, u128)>,
}

pub fn generate_ship(seed: u64, params: &GenParams, data: &GenData) -> Result<Ship, GenError> {
    generate_ship_timed(seed, params, data).map(|r| r.ship)
}

pub fn generate_ship_timed(
    seed: u64,
    params: &GenParams,
    data: &GenData,
) -> Result<GenReport, GenError> {
    let arch = data
        .archetypes
        .get(&params.archetype_id)
        .ok_or_else(|| GenError::UnknownArchetype(params.archetype_id.clone()))?;
    let mut timings: Vec<(&'static str, u128)> = Vec::new();
    let mut mark = Instant::now();
    let lap = |name: &'static str, timings: &mut Vec<(&'static str, u128)>, mark: &mut Instant| {
        timings.push((name, mark.elapsed().as_micros()));
        *mark = Instant::now();
    };

    // --- Hull ---------------------------------------------------------------
    let mut meta_rng = rng::stream(seed, "meta", 0);
    let deck_count = roll_range(&mut meta_rng, arch.decks.0 as i64, arch.decks.1 as i64) as u8;
    let mut hull_rng = rng::stream(seed, "hull", 0);
    let hull_plan = hull::generate_hull(&mut hull_rng, arch, deck_count);
    let actual_decks = hull_plan.deck_masks.len() as u8;
    lap("hull", &mut timings, &mut mark);

    // --- Template selection (guarantee- and budget-aware, fail-closed) ------
    // Interior cell budget from the rolled hull; only templates whose
    // minimum footprint need fits (with slack for corridors/walkways) are
    // candidates. Each retry attempt re-picks deterministically.
    let hull_cells: u32 = hull_plan.deck_masks.iter().map(|m| m.count() as u32).sum();
    let pick_template = |attempt: u64, exclude: &[String]| -> Result<&TemplateDef, GenError> {
        if !arch.template.is_empty() {
            return data
                .templates
                .templates
                .get(&arch.template)
                .ok_or_else(|| GenError::UnknownArchetype(arch.template.clone()));
        }
        let compatible = data
            .templates
            .compatible(&arch.guaranteed_roles, actual_decks);
        if compatible.is_empty() {
            return Err(GenError::NoCompatibleTemplate {
                archetype: arch.id.clone(),
                deck_count: actual_decks,
            });
        }
        let mut fitting: Vec<&TemplateDef> = compatible
            .iter()
            .copied()
            .filter(|t| t.min_cell_need() * 3 / 2 <= hull_cells)
            .filter(|t| !exclude.contains(&t.id))
            .collect();
        if fitting.is_empty() {
            // Every fitting template already failed an attempt; retry the
            // full fitting pool with fresh placement RNG rather than none.
            fitting = compatible
                .iter()
                .copied()
                .filter(|t| t.min_cell_need() * 3 / 2 <= hull_cells)
                .collect();
        }
        if fitting.is_empty() {
            // Smallest-need compatible template as a last resort.
            fitting = vec![compatible
                .iter()
                .copied()
                .min_by_key(|t| (t.min_cell_need(), t.id.clone()))
                .unwrap()];
        }
        let mut trng = rng::stream(seed, "template", attempt);
        let weights: Vec<u32> = vec![1; fitting.len()];
        Ok(fitting[weighted_choice(&mut trng, &weights).unwrap_or(0)])
    };
    let template: &TemplateDef = pick_template(0, &[])?;
    let role_params = RoleParams {
        weights: arch.role_weights.iter().copied().collect(),
        guaranteed: arch.guaranteed_roles.clone(),
        max_duplicates: arch.max_duplicates,
    };
    lap("template", &mut timings, &mut mark);

    let stamps: Vec<&crate::authoring::GoldenArea> = arch
        .golden_stamps
        .iter()
        .filter_map(|id| data.golden_areas.get(id))
        .collect();

    // --- Topology placement + compile + pre-damage validation (retries) -----
    let mut placed = None;
    let mut last_err: Option<GenError> = None;
    let mut template = template;
    let mut failed_templates: Vec<String> = Vec::new();
    for attempt in 0..TOPOLOGY_ATTEMPTS {
        template = pick_template(attempt, &failed_templates)?;
        let mut trng = rng::stream(seed, "topology", attempt);
        let mut candidate =
            match place_topology(&mut trng, template, &hull_plan.deck_masks, &role_params) {
                Ok(p) => p,
                Err(e) => {
                    last_err = Some(GenError::TopologyFailed(e.to_string()));
                    if blacklist_template_on(TopologyFailKind::Placement) {
                        failed_templates.push(template.id.clone());
                    }
                    continue;
                }
            };
        let stamped = match apply_golden_stamps(&mut candidate, &stamps, &hull_plan.deck_masks) {
            Ok(s) => s,
            Err(e) => {
                last_err = Some(GenError::TopologyFailed(e.to_string()));
                if blacklist_template_on(TopologyFailKind::Stamp) {
                    failed_templates.push(template.id.clone());
                }
                continue;
            }
        };
        let mut frng = rng::stream(seed, "residual_fill", attempt);
        residual_fill(
            &mut frng,
            &mut candidate,
            &hull_plan.deck_masks,
            &arch.filler_roles,
        );
        let (plan, _stale) = compile_authored(
            &candidate.topology,
            &DefaultModulePicker,
            &stamped.overrides,
        );
        if !plan.errors.is_empty() {
            last_err = Some(GenError::StructuralCompileFailed(plan.errors.clone()));
            continue;
        }
        let policy = ValidationPolicy::pre_damage(candidate.critical_path.clone());
        match validate(&plan, &candidate.topology, &policy) {
            Ok(_) => {
                placed = Some((candidate, plan, stamped));
                break;
            }
            Err(issues) => {
                last_err = Some(GenError::StructuralValidationFailed {
                    stage: ValidationStage::PreDamage,
                    issues: issues.iter().map(|i| i.to_string()).collect(),
                });
            }
        }
    }
    let (placed, _pre_plan, stamped) = placed.ok_or_else(|| GenError::RetriesExhausted {
        attempts: TOPOLOGY_ATTEMPTS,
        last: Box::new(last_err.unwrap_or(GenError::TopologyFailed("no attempt ran".into()))),
    })?;
    lap("topology", &mut timings, &mut mark);

    // --- Furnish (locks write back into topology portal states) -------------
    let (mut plan, _stale) =
        compile_authored(&placed.topology, &DefaultModulePicker, &stamped.overrides);
    let furnish_out = furnish::furnish(
        seed,
        &placed.topology,
        &mut plan,
        &data.furnishing,
        &stamped.skip_furnish,
    );
    let mut entities = furnish_out.entities;
    let mut next_entity_id = furnish_out.next_entity_id;
    for prop in &stamped.props {
        entities.push(authored_entity(prop, next_entity_id, &data.items));
        next_entity_id += 1;
    }
    lap("furnish", &mut timings, &mut mark);

    // --- Story --------------------------------------------------------------
    let mut story_rng = rng::stream(seed, "story", 0);
    let cause = story::choose_cause(&mut story_rng, arch, params.cause_override);
    let profile = story::profile_for(cause);
    let intactness = params.intactness_override.unwrap_or_else(|| {
        let mut r = rng::stream(seed, "intact", 0);
        let bucket = weighted_choice(&mut r, &[25, 50, 25]).unwrap_or(1);
        let (lo, hi) = match bucket {
            0 => (7000, 9800),
            1 => (3500, 7000),
            _ => (600, 3500),
        };
        roll_range(&mut r, lo, hi) as u16
    });
    lap("story", &mut timings, &mut mark);

    // --- Damage + recompile + post-damage validation (retries) ---------------
    let mut committed = None;
    let mut last_err: Option<GenError> = None;
    for attempt in 0..DAMAGE_ATTEMPTS {
        let mut topo2 = placed.topology.clone();
        let mut entities2 = entities.clone();
        let mut next_id2 = next_entity_id;
        let outcome = damage::apply_damage(
            seed,
            attempt,
            &mut topo2,
            &mut entities2,
            &mut next_id2,
            &profile,
            intactness,
            arch,
            &[placed.entry_room, placed.goal_room],
        );
        let drift_of = fragment_drift_map(&outcome);
        let (overrides, hazards) = match remap_stamp_for_drift(
            &stamped.overrides,
            &stamped.hazards,
            &placed.topology,
            &topo2,
            &drift_of,
        ) {
            Ok(v) => v,
            Err(e) => {
                last_err = Some(GenError::TopologyFailed(e));
                continue;
            }
        };
        let (mut plan2, stale) = compile_authored(&topo2, &DefaultModulePicker, &overrides);
        if !plan2.errors.is_empty() {
            last_err = Some(GenError::StructuralCompileFailed(plan2.errors.clone()));
            continue;
        }
        if stale
            .iter()
            .any(|s| matches!(s.class, StaleClass::Floor | StaleClass::Ceiling))
        {
            last_err = Some(GenError::StructuralCompileFailed(
                stale
                    .iter()
                    .filter(|s| matches!(s.class, StaleClass::Floor | StaleClass::Ceiling))
                    .map(|s| format!("stale override {} {}", s.key, s.module_id))
                    .collect(),
            ));
            continue;
        }
        apply_overlays(&mut plan2, &outcome);
        // Post-damage critical path: recompute over the surviving graph.
        let alive = |id: PlanRoomId| {
            topo2
                .rooms
                .iter()
                .any(|r| r.id == id && !r.cells.is_empty())
        };
        let links = surviving_links(&topo2);
        let critical_path = if alive(placed.entry_room) && alive(placed.goal_room) {
            crate::topology::room_path(placed.entry_room, placed.goal_room, &links)
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let severed_legally = critical_path.is_empty()
            && outcome.fractured
            && profile.allows_fragment_split
            && alive(placed.entry_room)
            && alive(placed.goal_room);
        if critical_path.is_empty() && !severed_legally && intactness >= 500 {
            if std::env::var("DERELICT_DEBUG").is_ok() {
                eprintln!(
                    "[damage attempt {attempt}] path destroyed: fractured={} entry_alive={} goal_alive={} rooms={} links={}",
                    outcome.fractured,
                    alive(placed.entry_room),
                    alive(placed.goal_room),
                    topo2.rooms.len(),
                    links.len()
                );
            }
            last_err = Some(GenError::StructuralValidationFailed {
                stage: ValidationStage::PostDamage,
                issues: vec!["critical path destroyed by damage".into()],
            });
            continue;
        }
        let policy = ValidationPolicy::post_damage(
            critical_path.clone(),
            if outcome.fractured {
                Some(outcome.fragment_of.clone())
            } else {
                None
            },
            profile.allows_fragment_split,
        );
        match validate(&plan2, &topo2, &policy) {
            Ok(_) => {
                committed = Some((
                    topo2,
                    plan2,
                    entities2,
                    next_id2,
                    outcome,
                    critical_path,
                    hazards,
                ));
                break;
            }
            Err(issues) => {
                if std::env::var("DERELICT_DEBUG").is_ok() {
                    eprintln!(
                        "[damage attempt {attempt}] validation: {:?}",
                        issues.iter().take(2).collect::<Vec<_>>()
                    );
                    for v in &topo2.verticals {
                        eprintln!(
                            "  vertical {} {} -> {} {}",
                            v.from_room,
                            v.from_cell.key(),
                            v.to_room,
                            v.to_cell.key()
                        );
                    }
                    for r in &topo2.rooms {
                        if [7u16, 68].contains(&r.id) {
                            eprintln!(
                                "  room {} deck {} cells {:?}",
                                r.id,
                                r.deck,
                                r.cells.iter().map(|c| c.key()).collect::<Vec<_>>()
                            );
                        }
                    }
                }
                last_err = Some(GenError::StructuralValidationFailed {
                    stage: ValidationStage::PostDamage,
                    issues: issues.iter().map(|i| i.to_string()).collect(),
                });
            }
        }
    }
    let (topology, plan, mut entities_final, _next_id, outcome, critical_path, hazards) = committed
        .ok_or_else(|| GenError::RetriesExhausted {
            attempts: DAMAGE_ATTEMPTS,
            last: Box::new(last_err.unwrap_or(GenError::TopologyFailed("damage".into()))),
        })?;
    lap("damage", &mut timings, &mut mark);

    // --- Loot ----------------------------------------------------------------
    loot::seed_loot(
        seed,
        &mut entities_final,
        &topology,
        data,
        &profile,
        intactness,
        params.loot_richness,
    );
    lap("loot", &mut timings, &mut mark);

    // --- Raster projection + room graph --------------------------------------
    let decks: Vec<Deck> = project_to_raster(&topology, &plan)
        .into_iter()
        .map(|layer| Deck { layer })
        .collect();
    let room_graph = build_room_graph(&topology, &outcome.depressurized);
    let mut fragments = outcome.fragments;
    if fragments.is_empty() && outcome.fractured {
        fragments = Vec::new();
    }
    lap("assemble", &mut timings, &mut mark);

    let ship = Ship {
        generator_version: GENERATOR_VERSION,
        seed,
        archetype_id: params.archetype_id.clone(),
        template_id: template.id.clone(),
        intactness,
        cause_of_loss: cause,
        topology,
        plan,
        entry_room: placed.entry_room,
        goal_room: placed.goal_room,
        critical_path,
        decks,
        room_graph,
        entities: entities_final,
        damage_events: outcome.events,
        fractured: outcome.fractured,
        fragments,
        hazard_overlay: hazards,
    };
    Ok(GenReport {
        ship,
        stage_micros: timings,
    })
}

#[derive(Clone, Copy)]
enum TopologyFailKind {
    Placement,
    Stamp,
}

/// Placement errors blacklist the template; stamp+offset errors do not.
fn blacklist_template_on(kind: TopologyFailKind) -> bool {
    matches!(kind, TopologyFailKind::Placement)
}

fn fragment_drift_map(outcome: &damage::DamageOutcome) -> BTreeMap<PlanRoomId, (i32, i32)> {
    let mut drift_of_frag: BTreeMap<u8, (i32, i32)> = BTreeMap::new();
    for f in &outcome.fragments {
        drift_of_frag.insert(f.id, f.drift);
    }
    let mut out = BTreeMap::new();
    for (room, frag) in &outcome.fragment_of {
        out.insert(*room, drift_of_frag.get(frag).copied().unwrap_or((0, 0)));
    }
    out
}

/// Stamp cosmetic damage overlays (decals, damaged variants) onto the
/// recompiled plan. Never touches topology or validation-relevant fields.
fn apply_overlays(plan: &mut StructuralPlan, outcome: &damage::DamageOutcome) {
    for (key, decal) in &outcome.cell_decals {
        if let Some(rec) = plan.occupancy.get_mut(key) {
            rec.decal = *decal;
        }
    }
    for key in &outcome.damaged_cells {
        if let Some(rec) = plan.occupancy.get_mut(key) {
            rec.variant = crate::structural::plan::DamageVariant::Damaged;
        }
        if let Some(f) = plan
            .floor_placements
            .iter_mut()
            .find(|f| &f.cell_key == key)
        {
            f.variant = crate::structural::plan::DamageVariant::Damaged;
        }
    }
    // Edges bordering damaged cells render damaged variants too.
    for edge in plan.edges.values_mut() {
        if edge.kind == EdgeKind::Breach {
            edge.variant = crate::structural::plan::DamageVariant::Breached;
        } else if outcome.damaged_cells.contains(&edge.source_cells[0].key())
            || outcome.damaged_cells.contains(&edge.source_cells[1].key())
        {
            edge.variant = crate::structural::plan::DamageVariant::Damaged;
        }
    }
    let variants: BTreeMap<String, crate::structural::plan::DamageVariant> = plan
        .edges
        .iter()
        .map(|(k, e)| (k.clone(), e.variant))
        .collect();
    for p in plan.placements.iter_mut() {
        if let Some(v) = variants.get(&p.edge_key) {
            p.variant = *v;
        }
    }
}

/// Room links surviving in a (possibly damaged) topology: interior portals
/// + vertical connections.
fn surviving_links(topology: &Topology) -> Vec<(PlanRoomId, PlanRoomId)> {
    let mut links: Vec<(PlanRoomId, PlanRoomId)> = Vec::new();
    for p in &topology.portals {
        if !p.exterior && p.to_room != crate::structural::plan::NO_ROOM {
            links.push((p.from_room, p.to_room));
        }
    }
    for v in &topology.verticals {
        links.push((v.from_room, v.to_room));
    }
    links.sort();
    links.dedup();
    links
}

fn build_room_graph(
    topology: &Topology,
    depressurized: &std::collections::BTreeSet<PlanRoomId>,
) -> RoomGraph {
    let mut nodes: Vec<RoomNode> = Vec::new();
    for room in &topology.rooms {
        let (mut x0, mut y0, mut x1, mut y1) = (i32::MAX, i32::MAX, i32::MIN, i32::MIN);
        for c in &room.cells {
            x0 = x0.min(c.x);
            y0 = y0.min(c.y);
            x1 = x1.max(c.x);
            y1 = y1.max(c.y);
        }
        nodes.push(RoomNode {
            id: room.id,
            deck: room.deck,
            kind: room.role,
            min: (x0, y0),
            max: (x1, y1),
            tile_count: room.cells.len() as u32,
            depressurized: depressurized.contains(&room.id),
            spans_room_id: None,
        });
    }
    let mut edges: Vec<RoomEdge> = Vec::new();
    for p in &topology.portals {
        if p.exterior || p.to_room == crate::structural::plan::NO_ROOM {
            continue;
        }
        let (a, b) = if p.from_room < p.to_room {
            (p.from_room, p.to_room)
        } else {
            (p.to_room, p.from_room)
        };
        let kind = if p.state == EdgeKind::Breach {
            EdgeKind2::Breach
        } else {
            EdgeKind2::Door
        };
        let kind = match kind {
            EdgeKind2::Breach => crate::model::EdgeKind::Breach,
            EdgeKind2::Door => crate::model::EdgeKind::Door,
        };
        if !edges.iter().any(|e| e.a == a && e.b == b && e.kind == kind) {
            edges.push(RoomEdge { a, b, kind });
        }
    }
    for v in &topology.verticals {
        let (a, b) = if v.from_room < v.to_room {
            (v.from_room, v.to_room)
        } else {
            (v.to_room, v.from_room)
        };
        let kind = crate::model::EdgeKind::VerticalShaft;
        if !edges.iter().any(|e| e.a == a && e.b == b && e.kind == kind) {
            edges.push(RoomEdge { a, b, kind });
        }
    }
    RoomGraph { nodes, edges }
}

enum EdgeKind2 {
    Door,
    Breach,
}

fn authored_entity(prop: &AuthoredProp, id: u32, items: &ItemRegistry) -> EntitySpec {
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
    let mut tags = vec!["authored_prop".into()];
    match prop.inventory_mode {
        InventoryMode::Explicit => {
            tags.push("authored_skip_loot".into());
            tags.push("authored_explicit".into());
            for s in &prop.inventory {
                tags.push(format!("content:{}:{}", s.item_id, s.qty));
            }
        }
        InventoryMode::LootTable => {
            tags.push("authored_skip_loot".into());
            if let Some(table) = prop.loot_table.as_deref().filter(|t| !t.is_empty()) {
                tags.push(format!("authored_loot_table:{table}"));
            }
        }
        InventoryMode::Empty => {
            tags.push("authored_skip_loot".into());
            tags.push("authored_empty".into());
        }
    }
    EntitySpec {
        id,
        kind: prop.kind,
        proto: prop.proto.clone(),
        pos: GridPos::new(prop.cell[0], prop.cell[1], deck),
        rotation: prop.rotation,
        locked: prop.locked,
        open: false,
        inventory,
        tags,
    }
}

#[cfg(test)]
mod stamp_retry_tests {
    use super::{blacklist_template_on, TopologyFailKind};

    #[test]
    fn stamp_errors_do_not_blacklist_templates() {
        assert!(blacklist_template_on(TopologyFailKind::Placement));
        assert!(!blacklist_template_on(TopologyFailKind::Stamp));
    }
}
