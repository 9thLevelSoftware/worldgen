//! Fail-closed structural plan validation — port of The Synaptic Sea's
//! `structural_plan_validator.gd`. Every issue fails the plan; there is no
//! warning tier. Reachability checks are stage-aware (pre-damage: whole
//! ship; post-damage: per fragment), everything else is unconditional.

use crate::structural::plan::*;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

pub const FLOOR_MODULES: [&str; 2] = ["floor_1x1", "corridor_floor_1x1"];

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ValidationStage {
    PreDamage,
    PostDamage,
}

#[derive(Clone, Debug)]
pub struct ValidationPolicy {
    pub stage: ValidationStage,
    /// room -> fragment id; None/empty when not fractured.
    pub fragment_of: Option<BTreeMap<RoomId, u8>>,
    /// Ordered room-id path from entry to goal.
    pub critical_path: Vec<RoomId>,
    /// Story-sanctioned severing of the critical path across fragments.
    pub allows_fragment_split: bool,
    /// When set, floor placements may use these module ids instead of `FLOOR_MODULES`.
    pub allowed_floor_modules: Option<Vec<String>>,
}

impl ValidationPolicy {
    pub fn pre_damage(critical_path: Vec<RoomId>) -> Self {
        Self {
            stage: ValidationStage::PreDamage,
            fragment_of: None,
            critical_path,
            allows_fragment_split: false,
            allowed_floor_modules: None,
        }
    }
    pub fn post_damage(
        critical_path: Vec<RoomId>,
        fragment_of: Option<BTreeMap<RoomId, u8>>,
        allows_fragment_split: bool,
    ) -> Self {
        Self {
            stage: ValidationStage::PostDamage,
            fragment_of,
            critical_path,
            allows_fragment_split,
            allowed_floor_modules: None,
        }
    }

    fn is_floor_module(&self, module_id: &str) -> bool {
        match &self.allowed_floor_modules {
            Some(list) => list.iter().any(|m| m == module_id),
            None => FLOOR_MODULES.contains(&module_id),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum IssueCode {
    CompilerError,
    OccupancyMalformed,
    FloorDuplicate,
    FloorUnknownRoom,
    FloorKeyMismatch,
    FloorOccupancyMismatch,
    FloorBadModule,
    FloorBadPose,
    FloorBijectionBroken,
    CeilingInvalid,
    CeilingOnVerticalOpening,
    SocketBindingsMissing,
    FloorOnlyPlan,
    EdgePlacementDuplicate,
    EdgePlacementOrphan,
    OpenEdgePlaced,
    EdgeKindMismatch,
    EdgeModuleMismatch,
    EdgeBadPose,
    RequiredEdgeUnplaced,
    PortalEndpointsInvalid,
    PortalHasNoEdge,
    PortalCompiledNonPortal,
    PortalBlockedBySolid,
    ReachabilityBroken,
    CriticalPathBroken,
    CriticalPathSevered,
}

#[derive(Clone, Debug)]
pub struct ValidationIssue {
    pub code: IssueCode,
    pub detail: String,
}

impl std::fmt::Display for ValidationIssue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}: {}", self.code, self.detail)
    }
}

#[derive(Clone, Debug, Default)]
pub struct ValidationStats {
    pub occupied_cells: usize,
    pub floor_placements: usize,
    pub ceiling_placements: usize,
    pub edges: usize,
    pub edge_placements: usize,
    pub socket_bindings: usize,
}

pub fn validate(
    plan: &StructuralPlan,
    topology: &Topology,
    policy: &ValidationPolicy,
) -> Result<ValidationStats, Vec<ValidationIssue>> {
    let mut issues: Vec<ValidationIssue> = Vec::new();
    let push = |code: IssueCode, detail: String, issues: &mut Vec<ValidationIssue>| {
        issues.push(ValidationIssue { code, detail });
    };

    // --- 1. Compiler diagnostics automatically fail validation -------------
    for e in &plan.errors {
        push(
            IssueCode::CompilerError,
            format!("compiler error: {e}"),
            &mut issues,
        );
    }

    let room_of: BTreeMap<RoomId, &RoomSpec> = topology.rooms.iter().map(|r| (r.id, r)).collect();

    // --- 2. Occupancy round-trip -------------------------------------------
    if plan.occupancy.is_empty() {
        push(
            IssueCode::OccupancyMalformed,
            "occupancy is empty".into(),
            &mut issues,
        );
        return Err(issues);
    }
    for (key, rec) in &plan.occupancy {
        if &rec.cell.key() != key {
            push(
                IssueCode::OccupancyMalformed,
                format!(
                    "occupancy key {key} does not reconstruct from cell {:?}",
                    rec.cell
                ),
                &mut issues,
            );
        }
        if rec.room_id == NO_ROOM {
            push(
                IssueCode::OccupancyMalformed,
                format!("occupancy {key} has no room"),
                &mut issues,
            );
        }
    }

    // --- 3. Floors: bijection with occupancy + pose/module/room checks -----
    let mut seen_floor_keys: BTreeSet<&str> = BTreeSet::new();
    for f in &plan.floor_placements {
        if !seen_floor_keys.insert(&f.cell_key) {
            push(
                IssueCode::FloorDuplicate,
                format!("duplicate floor {}", f.cell_key),
                &mut issues,
            );
            continue;
        }
        let Some(room) = room_of.get(&f.room_id) else {
            push(
                IssueCode::FloorUnknownRoom,
                format!("floor {} room {}", f.cell_key, f.room_id),
                &mut issues,
            );
            continue;
        };
        if f.cell.key() != f.cell_key {
            push(
                IssueCode::FloorKeyMismatch,
                format!("floor {} cell/key mismatch", f.cell_key),
                &mut issues,
            );
        }
        match plan.occupancy.get(&f.cell_key) {
            None => push(
                IssueCode::FloorOccupancyMismatch,
                format!("floor {} has no occupancy cell", f.cell_key),
                &mut issues,
            ),
            Some(occ) => {
                if occ.room_id != f.room_id {
                    push(
                        IssueCode::FloorOccupancyMismatch,
                        format!("floor {} room disagrees with occupancy", f.cell_key),
                        &mut issues,
                    );
                }
                if occ.module_id != f.module_id {
                    push(
                        IssueCode::FloorOccupancyMismatch,
                        format!("floor {} module disagrees with occupancy", f.cell_key),
                        &mut issues,
                    );
                }
            }
        }
        if room.deck != f.cell.deck {
            push(
                IssueCode::FloorOccupancyMismatch,
                format!("floor {} deck mismatch", f.cell_key),
                &mut issues,
            );
        }
        if !policy.is_floor_module(&f.module_id) {
            push(
                IssueCode::FloorBadModule,
                format!("floor {} module '{}'", f.cell_key, f.module_id),
                &mut issues,
            );
        }
        if f.position != f.cell.world_pos() || f.yaw_degrees != 0 {
            push(
                IssueCode::FloorBadPose,
                format!("floor {} pose", f.cell_key),
                &mut issues,
            );
        }
    }
    if plan.floor_placements.len() != plan.occupancy.len() {
        push(
            IssueCode::FloorBijectionBroken,
            format!(
                "{} floors vs {} occupied cells",
                plan.floor_placements.len(),
                plan.occupancy.len()
            ),
            &mut issues,
        );
    }
    for key in plan.occupancy.keys() {
        if !seen_floor_keys.contains(key.as_str()) {
            push(
                IssueCode::FloorBijectionBroken,
                format!("occupancy cell {key} has no floor placement"),
                &mut issues,
            );
        }
    }

    // --- 4. Ceilings mirror floors, vertical-opening exemption -------------
    let vertical_cells: BTreeSet<String> = topology
        .verticals
        .iter()
        .flat_map(|v| [v.from_cell.key(), v.to_cell.key()])
        .collect();
    let mut seen_ceiling: BTreeSet<&str> = BTreeSet::new();
    for c in &plan.ceiling_placements {
        if !seen_ceiling.insert(&c.cell_key) {
            push(
                IssueCode::CeilingInvalid,
                format!("duplicate ceiling {}", c.cell_key),
                &mut issues,
            );
        }
        if vertical_cells.contains(&c.cell_key) {
            push(
                IssueCode::CeilingOnVerticalOpening,
                format!(
                    "ceiling placement on authored vertical opening {}",
                    c.cell_key
                ),
                &mut issues,
            );
        }
        if !plan.occupancy.contains_key(&c.cell_key) {
            push(
                IssueCode::CeilingInvalid,
                format!("ceiling {} not on occupied cell", c.cell_key),
                &mut issues,
            );
        }
        if c.position != c.cell.world_pos() {
            push(
                IssueCode::CeilingInvalid,
                format!("ceiling {} pose", c.cell_key),
                &mut issues,
            );
        }
        if !c.module_id.contains("ceiling") {
            push(
                IssueCode::CeilingInvalid,
                format!("ceiling {} module '{}'", c.cell_key, c.module_id),
                &mut issues,
            );
        }
    }
    for key in plan.occupancy.keys() {
        if !vertical_cells.contains(key) && !seen_ceiling.contains(key.as_str()) {
            push(
                IssueCode::CeilingInvalid,
                format!("occupied cell {key} has no ceiling"),
                &mut issues,
            );
        }
    }

    // --- 5. Socket bindings mandatory --------------------------------------
    if plan.socket_bindings.is_empty() {
        push(
            IssueCode::SocketBindingsMissing,
            "socket_bindings missing".into(),
            &mut issues,
        );
    }
    for b in &plan.socket_bindings {
        if b.placement_id.is_empty()
            || b.socket_id.is_empty()
            || b.neighbor_placement_id.is_empty()
            || b.neighbor_socket_id.is_empty()
        {
            push(
                IssueCode::SocketBindingsMissing,
                "socket binding with empty field".into(),
                &mut issues,
            );
            break;
        }
    }

    // --- 6. Not floor-only ---------------------------------------------------
    let has_enclosure = plan.placements.iter().any(|p| {
        p.module_id.contains("wall")
            || p.module_id.contains("door")
            || p.module_id.contains("portal")
            || p.module_id.contains("bulkhead")
    });
    if !has_enclosure {
        push(
            IssueCode::FloorOnlyPlan,
            "no wall/door/portal placements at all".into(),
            &mut issues,
        );
    }

    // --- 7. Edge placements: forward ----------------------------------------
    let mut seen_edge_keys: BTreeSet<&str> = BTreeSet::new();
    for p in &plan.placements {
        if !seen_edge_keys.insert(&p.edge_key) {
            push(
                IssueCode::EdgePlacementDuplicate,
                format!("duplicate edge placement {}", p.edge_key),
                &mut issues,
            );
            continue;
        }
        let Some(edge) = plan.edges.get(&p.edge_key) else {
            push(
                IssueCode::EdgePlacementOrphan,
                format!("placement {} has no edge record", p.edge_key),
                &mut issues,
            );
            continue;
        };
        if p.kind == EdgeKind::Open {
            push(
                IssueCode::OpenEdgePlaced,
                format!("OPEN edge must not have a placement: {}", p.edge_key),
                &mut issues,
            );
        }
        if policy.is_floor_module(&p.module_id) {
            push(
                IssueCode::EdgeModuleMismatch,
                format!("floor module on edge {}", p.edge_key),
                &mut issues,
            );
        }
        if p.kind != edge.kind {
            push(
                IssueCode::EdgeKindMismatch,
                format!("placement kind differs from edge {}", p.edge_key),
                &mut issues,
            );
        }
        if p.module_id != edge.module_id {
            push(
                IssueCode::EdgeModuleMismatch,
                format!("placement module differs from edge {}", p.edge_key),
                &mut issues,
            );
        }
        // Pose round-trip.
        if edge_key(p.cell, p.direction) != p.edge_key
            || p.position != edge_world_position(p.cell, p.direction)
            || p.yaw_degrees != p.direction.yaw_degrees()
        {
            push(
                IssueCode::EdgeBadPose,
                format!("edge {} pose round-trip failed", p.edge_key),
                &mut issues,
            );
        }
    }

    // --- 8. Edges: reverse — every required edge has a placement ------------
    for (key, edge) in &plan.edges {
        if edge.kind != EdgeKind::Open
            && edge.wrapper_required
            && !seen_edge_keys.contains(key.as_str())
        {
            push(
                IssueCode::RequiredEdgeUnplaced,
                format!("required edge has no placement: {key}"),
                &mut issues,
            );
        }
    }

    // --- 9. Portal endpoints vs authored topology ---------------------------
    for portal in &topology.portals {
        let interior = !portal.exterior && portal.to_room != NO_ROOM;
        if !room_of.contains_key(&portal.from_room)
            || (interior && !room_of.contains_key(&portal.to_room))
        {
            push(
                IssueCode::PortalEndpointsInvalid,
                format!(
                    "portal rooms unknown {} -> {}",
                    portal.from_room, portal.to_room
                ),
                &mut issues,
            );
            continue;
        }
        let owner = plan
            .occupancy
            .get(&portal.from_cell.key())
            .map(|o| o.room_id);
        let owner_ok = owner == Some(portal.from_room);
        let to_ok = if interior {
            plan.occupancy.get(&portal.to_cell.key()).map(|o| o.room_id) == Some(portal.to_room)
        } else {
            !plan.occupancy.contains_key(&portal.to_cell.key())
        };
        if !owner_ok || !to_ok {
            push(
                IssueCode::PortalEndpointsInvalid,
                format!(
                    "portal endpoints are not reciprocal {} -> {}",
                    portal.from_room, portal.to_room
                ),
                &mut issues,
            );
            continue;
        }
        let Some(dir) = Dir::between(portal.from_cell, portal.to_cell) else {
            push(
                IssueCode::PortalEndpointsInvalid,
                format!(
                    "portal endpoints not adjacent {} -> {}",
                    portal.from_room, portal.to_room
                ),
                &mut issues,
            );
            continue;
        };
        let key = edge_key(portal.from_cell, dir);
        match plan.edges.get(&key) {
            None => push(
                IssueCode::PortalHasNoEdge,
                format!("portal has no canonical edge {key}"),
                &mut issues,
            ),
            Some(edge) => {
                if !edge.portal {
                    push(
                        IssueCode::PortalCompiledNonPortal,
                        format!("portal edge was compiled as non-portal {key}"),
                        &mut issues,
                    );
                }
                if edge.kind == EdgeKind::Solid {
                    push(
                        IssueCode::PortalBlockedBySolid,
                        format!("topology-connected rooms blocked by SOLID edge {key}"),
                        &mut issues,
                    );
                }
            }
        }
    }

    // --- 10/11. Reachability: flood fill + critical path (stage-aware) ------
    check_reachability(plan, topology, policy, &mut issues);

    if issues.is_empty() {
        Ok(ValidationStats {
            occupied_cells: plan.occupancy.len(),
            floor_placements: plan.floor_placements.len(),
            ceiling_placements: plan.ceiling_placements.len(),
            edges: plan.edges.len(),
            edge_placements: plan.placements.len(),
            socket_bindings: plan.socket_bindings.len(),
        })
    } else {
        Err(issues)
    }
}

/// Cell adjacency graph from non-SOLID edges + vertical connections, then:
/// - PreDamage: all occupied cells form one component; critical path rooms
///   pairwise reachable.
/// - PostDamage: cells of each fragment form one component; critical path
///   checked within fragments, severing across fragments allowed only by
///   policy.
fn check_reachability(
    plan: &StructuralPlan,
    topology: &Topology,
    policy: &ValidationPolicy,
    issues: &mut Vec<ValidationIssue>,
) {
    // Build adjacency: every passable edge (Open/Door/Locked/Hatch/Breach —
    // Locked counts: it is an openable boundary, not a wall) links its two
    // source cells; vertical connections link decks.
    let keys: Vec<String> = plan.occupancy.keys().cloned().collect();
    let mut links: Vec<(String, String)> = Vec::new();
    for edge in plan.edges.values() {
        if edge.kind.passable() {
            links.push((edge.source_cells[0].key(), edge.source_cells[1].key()));
        }
    }
    for v in &topology.verticals {
        links.push((v.from_cell.key(), v.to_cell.key()));
    }
    let mut graph: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for key in &keys {
        graph.insert(key.clone(), Vec::new());
    }
    for (a, b) in links {
        if graph.contains_key(&a) && graph.contains_key(&b) {
            graph.get_mut(&a).unwrap().push(b.clone());
            graph.get_mut(&b).unwrap().push(a);
        }
    }

    let component_of = compute_components(&graph);

    // Fragment id per cell (via room), when fractured.
    let frag_of_cell = |key: &str| -> u8 {
        match (&policy.fragment_of, plan.occupancy.get(key)) {
            (Some(map), Some(rec)) => map.get(&rec.room_id).copied().unwrap_or(0),
            _ => 0,
        }
    };

    // Group cells by fragment; each group must be a single component.
    let mut by_fragment: BTreeMap<u8, Vec<&String>> = BTreeMap::new();
    for key in &keys {
        by_fragment.entry(frag_of_cell(key)).or_default().push(key);
    }
    for (frag, cells) in &by_fragment {
        let comps: BTreeSet<u32> = cells.iter().map(|k| component_of[k.as_str()]).collect();
        if comps.len() > 1 {
            // Name one cell (and its room) per component for debuggability.
            let mut samples: Vec<String> = Vec::new();
            for comp_id in &comps {
                if let Some(k) = cells.iter().find(|k| component_of[k.as_str()] == *comp_id) {
                    let room = plan
                        .occupancy
                        .get(k.as_str())
                        .map(|r| r.room_id)
                        .unwrap_or(0);
                    samples.push(format!("{k}(room {room})"));
                }
            }
            issues.push(ValidationIssue {
                code: IssueCode::ReachabilityBroken,
                detail: format!(
                    "flood-fill/topology reachability disagreement: fragment {frag} splits into {} components [{}]",
                    comps.len(),
                    samples.join(", ")
                ),
            });
        }
    }

    // Critical path pairwise reachability.
    let cell_of_room: BTreeMap<RoomId, &String> = {
        let mut m: BTreeMap<RoomId, &String> = BTreeMap::new();
        for (key, rec) in &plan.occupancy {
            m.entry(rec.room_id).or_insert(key);
        }
        m
    };
    for pair in policy.critical_path.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        let (Some(ka), Some(kb)) = (cell_of_room.get(&a), cell_of_room.get(&b)) else {
            issues.push(ValidationIssue {
                code: IssueCode::CriticalPathBroken,
                detail: format!("critical-path room missing cells: {a} -> {b}"),
            });
            continue;
        };
        if component_of[ka.as_str()] == component_of[kb.as_str()] {
            continue;
        }
        // Unreachable: legal only post-damage across fragments with story
        // sanction.
        let cross_fragment = frag_of_cell(ka) != frag_of_cell(kb);
        if policy.stage == ValidationStage::PostDamage
            && cross_fragment
            && policy.allows_fragment_split
        {
            continue;
        }
        issues.push(ValidationIssue {
            code: if cross_fragment {
                IssueCode::CriticalPathSevered
            } else {
                IssueCode::CriticalPathBroken
            },
            detail: format!("flood-fill/topology reachability disagreement: {a} -> {b}"),
        });
    }
}

fn compute_components(graph: &BTreeMap<String, Vec<String>>) -> BTreeMap<&str, u32> {
    let mut component: BTreeMap<&str, u32> = BTreeMap::new();
    let mut next = 0u32;
    for start in graph.keys() {
        if component.contains_key(start.as_str()) {
            continue;
        }
        next += 1;
        let mut queue = VecDeque::from([start.as_str()]);
        component.insert(start.as_str(), next);
        while let Some(k) = queue.pop_front() {
            for n in &graph[k] {
                if !component.contains_key(n.as_str()) {
                    component.insert(n.as_str(), next);
                    queue.push_back(n.as_str());
                }
            }
        }
    }
    component
}
