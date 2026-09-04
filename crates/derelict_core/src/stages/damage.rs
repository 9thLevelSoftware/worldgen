//! Stage: damage/wreck pass, gated by intactness (0..=10000 bp), operating
//! on the AUTHORED TOPOLOGY (the single mutable authority). Breaches are
//! modeled as damage portals (state = Breach), holes as removed occupancy
//! cells, and fracture as an integer drift applied to one side's rooms —
//! the structural plan is recompiled afterwards, so every canonical key is
//! re-derived rather than patched (no re-keying drift bugs by construction).
//!
//! Cosmetic overlays (scorch decals, damaged module variants) are returned
//! separately and stamped onto the recompiled plan; they never affect
//! topology or validation.

use crate::archetype::ShipArchetype;
use crate::model::{DamageEvent, DamageEventKind, EntityKind, EntitySpec, GridPos, ShipFragment};
use crate::rng::{self, roll_bp, roll_range, weighted_choice};
use crate::role::Role;
use crate::stages::story::DamageProfile;
use crate::structural::plan::{Cell, Dir, EdgeKind, PortalIntent, RoomId, Topology, NO_ROOM};
use std::collections::{BTreeMap, BTreeSet};

pub const FRACTURE_THRESHOLD_BP: u16 = 3500;

#[derive(Default)]
pub struct DamageOutcome {
    pub events: Vec<DamageEvent>,
    pub depressurized: BTreeSet<RoomId>,
    pub fractured: bool,
    pub fragments: Vec<ShipFragment>,
    pub fragment_of: BTreeMap<RoomId, u8>,
    /// Cosmetic overlays keyed by cell key.
    pub cell_decals: BTreeMap<String, u8>,
    pub damaged_cells: BTreeSet<String>,
}

#[allow(clippy::too_many_arguments)]
pub fn apply_damage(
    master_seed: u64,
    attempt: u64,
    topology: &mut Topology,
    entities: &mut Vec<EntitySpec>,
    next_entity_id: &mut u32,
    profile: &DamageProfile,
    intactness: u16,
    arch: &ShipArchetype,
    protected: &[RoomId],
    protected_links: &[(RoomId, RoomId)],
) -> DamageOutcome {
    let mut out = DamageOutcome::default();
    let damage_bp = (10_000 - intactness) as i64;

    breach_pass(
        master_seed,
        attempt,
        topology,
        entities,
        profile,
        damage_bp,
        arch,
        protected,
        &mut out,
    );
    scorch_pass(master_seed, attempt, topology, profile, &mut out);
    seal_doors_pass(master_seed, topology, entities, profile, protected_links);

    // Fracture is story-gated: causes that cannot legally sever the ship
    // (pirates, plague) never tear it in half — they take heavier breach
    // damage instead of an impossible split.
    if intactness < FRACTURE_THRESHOLD_BP && profile.allows_fragment_split {
        fracture_pass(
            master_seed,
            attempt,
            topology,
            entities,
            next_entity_id,
            protected,
            &mut out,
        );
    }

    body_pass(
        master_seed,
        attempt,
        topology,
        entities,
        next_entity_id,
        profile,
        damage_bp,
    );

    repair_connectivity(
        topology,
        &out.fragment_of,
        entities,
        next_entity_id,
        protected,
    );

    if matches!(profile.cause, crate::model::CauseOfLoss::Depressurization) {
        for room in &topology.rooms {
            out.depressurized.insert(room.id);
        }
    }
    out
}

/// After damage, every fragment must be internally connected. Rooms cut off
/// by pruned doors reconnect through standing-passable Door portals to an
/// adjacent reachable room; rooms with no adjacency left are destroyed
/// outright. Runs until each fragment is one component.
fn repair_connectivity(
    topology: &mut Topology,
    fragment_of: &BTreeMap<RoomId, u8>,
    entities: &mut Vec<EntitySpec>,
    next_entity_id: &mut u32,
    protected: &[RoomId],
) {
    // Each iteration restores a standing-passable Door or destroys at least
    // one whole stray COMPONENT, so iterations are bounded by the component count.
    for _ in 0..64 {
        let alive: Vec<RoomId> = topology.rooms.iter().map(|r| r.id).collect();
        if alive.is_empty() {
            return;
        }
        let mut adj: BTreeMap<RoomId, Vec<RoomId>> = BTreeMap::new();
        for p in &topology.portals {
            if !p.exterior && p.to_room != NO_ROOM && p.state.standing_passable() {
                adj.entry(p.from_room).or_default().push(p.to_room);
                adj.entry(p.to_room).or_default().push(p.from_room);
            }
        }
        for v in &topology.verticals {
            adj.entry(v.from_room).or_default().push(v.to_room);
            adj.entry(v.to_room).or_default().push(v.from_room);
        }
        let frag = |id: RoomId| fragment_of.get(&id).copied().unwrap_or(0);
        let mut comp: BTreeMap<RoomId, u32> = BTreeMap::new();
        let mut next = 0u32;
        for &start in &alive {
            if comp.contains_key(&start) {
                continue;
            }
            next += 1;
            let mut stack = vec![start];
            comp.insert(start, next);
            while let Some(cur) = stack.pop() {
                for n in adj.get(&cur).cloned().unwrap_or_default() {
                    if frag(n) == frag(cur) && !comp.contains_key(&n) {
                        comp.insert(n, next);
                        stack.push(n);
                    }
                }
            }
        }
        let cell_count = |id: RoomId| {
            topology
                .rooms
                .iter()
                .find(|r| r.id == id)
                .map(|r| r.cells.len())
                .unwrap_or(0)
        };
        let mut sizes: BTreeMap<(u8, u32), usize> = BTreeMap::new();
        for &id in &alive {
            *sizes.entry((frag(id), comp[&id])).or_insert(0) += cell_count(id);
        }
        // Main component per fragment: protected rooms (entry/goal) anchor
        // it — the ship must stay navigable around them — then size.
        let mut main_comp: BTreeMap<u8, u32> = BTreeMap::new();
        let rank = |f: u8, c: u32| -> (u32, usize) {
            let has_protected = protected
                .iter()
                .any(|id| comp.get(id) == Some(&c) && frag(*id) == f);
            (u32::from(has_protected), sizes[&(f, c)])
        };
        for &(f, c) in sizes.keys() {
            match main_comp.get(&f) {
                Some(&mc) if rank(f, mc) >= rank(f, c) => {}
                _ => {
                    main_comp.insert(f, c);
                }
            }
        }
        // Group stray rooms by their (fragment, component).
        let mut stray_comps: BTreeMap<(u8, u32), Vec<RoomId>> = BTreeMap::new();
        for &id in &alive {
            let key = (frag(id), comp[&id]);
            if main_comp.get(&key.0) != Some(&key.1) {
                stray_comps.entry(key).or_default().push(id);
            }
        }
        if std::env::var("DERELICT_DEBUG").is_ok() {
            eprintln!("  [repair] stray_comps={:?} sizes={:?}", stray_comps, sizes);
        }
        if stray_comps.is_empty() {
            return;
        }
        let cells_of: BTreeMap<RoomId, BTreeSet<(u8, i32, i32)>> = topology
            .rooms
            .iter()
            .map(|r| (r.id, r.cells.iter().map(|c| (c.deck, c.x, c.y)).collect()))
            .collect();
        let is_main = |id: RoomId| main_comp.get(&frag(id)) == Some(&comp[&id]);
        let mut progressed = false;
        // Reconnect every stray component that touches the main component.
        for ((_f, _c), rooms) in &stray_comps {
            let mut connected = false;
            'search: for &sid in rooms {
                for &oid in &alive {
                    if !is_main(oid) || frag(oid) != frag(sid) {
                        continue;
                    }
                    for &(d, x, y) in &cells_of[&sid] {
                        for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                            if cells_of[&oid].contains(&(d, x + dx, y + dy)) {
                                let from_cell = Cell::new(d, x, y);
                                let to_cell = Cell::new(d, x + dx, y + dy);
                                let key = crate::structural::plan::edge_key(
                                    from_cell,
                                    Dir::between(from_cell, to_cell).unwrap(),
                                );
                                let mut restored = false;
                                for portal in topology.portals.iter_mut() {
                                    let Some(portal_dir) =
                                        Dir::between(portal.from_cell, portal.to_cell)
                                    else {
                                        continue;
                                    };
                                    if !portal.exterior
                                        && portal.to_room != NO_ROOM
                                        && crate::structural::plan::edge_key(
                                            portal.from_cell,
                                            portal_dir,
                                        ) == key
                                    {
                                        portal.state = EdgeKind::Door;
                                        restored = true;
                                        break;
                                    }
                                }
                                if !restored {
                                    topology.portals.push(PortalIntent {
                                        from_room: sid,
                                        to_room: oid,
                                        from_cell,
                                        to_cell,
                                        state: EdgeKind::Door,
                                        exterior: false,
                                    });
                                    let tag = format!("edge:{key}");
                                    if !entities.iter().any(|e| {
                                        e.kind == EntityKind::Door && e.tags.contains(&tag)
                                    }) {
                                        let direction = Dir::between(from_cell, to_cell).unwrap();
                                        let (pos, rotation) =
                                            door_pos_rotation(from_cell, direction);
                                        entities.push(EntitySpec {
                                            id: *next_entity_id,
                                            kind: EntityKind::Door,
                                            proto: "door_basic".into(),
                                            pos,
                                            rotation,
                                            locked: false,
                                            open: false,
                                            inventory: Vec::new(),
                                            tags: vec![tag],
                                        });
                                        *next_entity_id += 1;
                                    }
                                }
                                connected = true;
                                break 'search;
                            }
                        }
                    }
                }
            }
            progressed = progressed || connected;
        }
        if progressed {
            dedup_portals(topology);
            continue;
        }
        // Nothing touches the main component: destroy the smallest
        // expendable stray component wholesale (blown to space).
        let doomed_comp = stray_comps
            .iter()
            .filter(|(_, rooms)| rooms.iter().all(|id| !protected.contains(id)))
            .min_by_key(|((f, c), _)| (sizes[&(*f, *c)], *f, *c))
            .map(|(_, rooms)| rooms.clone());
        let Some(rooms) = doomed_comp else {
            return; // only protected components are stray; leave to validation
        };
        let mut doomed: BTreeSet<(u8, i32, i32)> = BTreeSet::new();
        for id in rooms {
            doomed.extend(cells_of[&id].iter().copied());
        }
        remove_cells(topology, &doomed, entities);
    }
}

fn occupied_map(topology: &Topology) -> BTreeMap<(u8, i32, i32), RoomId> {
    let mut m = BTreeMap::new();
    for room in &topology.rooms {
        for c in &room.cells {
            m.insert((c.deck, c.x, c.y), room.id);
        }
    }
    m
}

/// Remove a set of cells from the topology: room cells shrink (empty rooms
/// are dropped), portals with a removed endpoint are pruned, verticals with
/// a removed endpoint are pruned, and loose entities standing on removed
/// cells are destroyed. Door entities whose portal disappeared go too.
fn remove_cells(
    topology: &mut Topology,
    cells: &BTreeSet<(u8, i32, i32)>,
    entities: &mut Vec<EntitySpec>,
) {
    for room in topology.rooms.iter_mut() {
        room.cells.retain(|c| !cells.contains(&(c.deck, c.x, c.y)));
    }
    // A hole can split a room's cells into islands; the minority islands are
    // torn away too (iterate until stable - deleting can cascade).
    loop {
        let mut extra: BTreeSet<(u8, i32, i32)> = BTreeSet::new();
        for room in topology.rooms.iter() {
            if room.cells.len() <= 1 {
                continue;
            }
            let mut set: BTreeSet<(u8, i32, i32)> =
                room.cells.iter().map(|c| (c.deck, c.x, c.y)).collect();
            let mut comps: Vec<Vec<(u8, i32, i32)>> = Vec::new();
            while let Some(&start) = set.iter().next() {
                set.remove(&start);
                let mut comp = vec![start];
                let mut stack = vec![start];
                while let Some((d, x, y)) = stack.pop() {
                    for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                        let n = (d, x + dx, y + dy);
                        if set.remove(&n) {
                            comp.push(n);
                            stack.push(n);
                        }
                    }
                }
                comps.push(comp);
            }
            if comps.len() > 1 {
                comps.sort_by_key(|c| usize::MAX - c.len());
                for comp in comps.into_iter().skip(1) {
                    extra.extend(comp);
                }
            }
        }
        if extra.is_empty() {
            break;
        }
        for room in topology.rooms.iter_mut() {
            room.cells.retain(|c| !extra.contains(&(c.deck, c.x, c.y)));
        }
        entities.retain(|e| {
            e.kind == EntityKind::Door || !extra.contains(&(e.pos.deck, e.pos.x, e.pos.y))
        });
    }
    topology.rooms.retain(|r| !r.cells.is_empty());
    let alive: BTreeSet<RoomId> = topology.rooms.iter().map(|r| r.id).collect();
    let occupied = occupied_map(topology);
    // Portals whose endpoint cell died get RELOCATED to another shared
    // boundary between the same two rooms when one exists; only portals
    // with no surviving boundary are pruned.
    let cells_of: BTreeMap<RoomId, Vec<(i32, i32, u8)>> = topology
        .rooms
        .iter()
        .map(|r| (r.id, r.cells.iter().map(|c| (c.x, c.y, c.deck)).collect()))
        .collect();
    for p in topology.portals.iter_mut() {
        if p.exterior || p.to_room == NO_ROOM {
            continue;
        }
        let from_ok =
            occupied.get(&(p.from_cell.deck, p.from_cell.x, p.from_cell.y)) == Some(&p.from_room);
        let to_ok = occupied.get(&(p.to_cell.deck, p.to_cell.x, p.to_cell.y)) == Some(&p.to_room);
        if from_ok && to_ok {
            continue;
        }
        let (Some(fa), Some(fb)) = (cells_of.get(&p.from_room), cells_of.get(&p.to_room)) else {
            continue;
        };
        let bset: BTreeSet<(i32, i32, u8)> = fb.iter().copied().collect();
        let mut found = None;
        for &(x, y, d) in fa {
            for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                if bset.contains(&(x + dx, y + dy, d)) {
                    found = Some((Cell::new(d, x, y), Cell::new(d, x + dx, y + dy)));
                    break;
                }
            }
            if found.is_some() {
                break;
            }
        }
        if let Some((ca, cb)) = found {
            p.from_cell = ca;
            p.to_cell = cb;
        }
    }
    topology.portals.retain(|p| {
        if !alive.contains(&p.from_room) {
            return false;
        }
        if occupied.get(&(p.from_cell.deck, p.from_cell.x, p.from_cell.y)) != Some(&p.from_room) {
            return false;
        }
        if p.exterior || p.to_room == NO_ROOM {
            true
        } else {
            alive.contains(&p.to_room)
                && occupied.get(&(p.to_cell.deck, p.to_cell.x, p.to_cell.y)) == Some(&p.to_room)
        }
    });
    dedup_portals(topology);
    topology.verticals.retain(|v| {
        occupied.get(&(v.from_cell.deck, v.from_cell.x, v.from_cell.y)) == Some(&v.from_room)
            && occupied.get(&(v.to_cell.deck, v.to_cell.x, v.to_cell.y)) == Some(&v.to_room)
    });
    entities
        .retain(|e| e.kind == EntityKind::Door || !cells.contains(&(e.pos.deck, e.pos.x, e.pos.y)));
    let portal_edge_keys: BTreeSet<String> = topology
        .portals
        .iter()
        .filter_map(|p| {
            Dir::between(p.from_cell, p.to_cell)
                .map(|d| crate::structural::plan::edge_key(p.from_cell, d))
        })
        .collect();
    entities.retain(|e| {
        if e.kind != EntityKind::Door {
            return true;
        }
        e.tags
            .iter()
            .find_map(|t| t.strip_prefix("edge:"))
            .map(|key| portal_edge_keys.contains(key))
            .unwrap_or(true)
    });
}

#[allow(clippy::too_many_arguments)]
fn breach_pass(
    master_seed: u64,
    attempt: u64,
    topology: &mut Topology,
    entities: &mut Vec<EntitySpec>,
    profile: &DamageProfile,
    damage_bp: i64,
    arch: &ShipArchetype,
    protected: &[RoomId],
    out: &mut DamageOutcome,
) {
    let mut rng = rng::stream(master_seed, "breach", attempt);
    if damage_bp < 800 {
        return;
    }
    let base = arch.max_breaches as i64 * damage_bp / 10_000;
    let min = if damage_bp >= 3000 { 1 } else { 0 };
    let n_breaches = (base + roll_range(&mut rng, -1, 1)).clamp(min, arch.max_breaches as i64);

    let role_of: BTreeMap<RoomId, Role> = topology.rooms.iter().map(|r| (r.id, r.role)).collect();
    let mut placed: Vec<Cell> = Vec::new();
    for _ in 0..n_breaches {
        let occupied = occupied_map(topology);
        let mut cands: Vec<Cell> = Vec::new();
        let mut weights: Vec<u32> = Vec::new();
        for (&(deck, x, y), room_id) in &occupied {
            if protected.contains(room_id) {
                continue; // never blow holes in the entry or goal rooms
            }
            let cell = Cell::new(deck, x, y);
            let boundary = Dir::ALL.iter().any(|d| {
                let n = cell.neighbor(*d);
                !occupied.contains_key(&(n.deck, n.x, n.y))
            });
            if !boundary {
                continue;
            }
            if placed
                .iter()
                .any(|p| p.deck == deck && (p.x - x).abs() + (p.y - y).abs() < 3)
            {
                continue;
            }
            let biased = role_of
                .get(room_id)
                .map(|r| profile.breach_bias_rooms.contains(r))
                .unwrap_or(false);
            cands.push(cell);
            weights.push(if biased { 8 } else { 1 });
        }
        let Some(pick) = weighted_choice(&mut rng, &weights) else {
            continue;
        };
        let origin = cands[pick];
        placed.push(origin);

        // Hole: the origin cell always; ring neighbors probabilistically at
        // heavy damage (cell scale is 4 m — holes stay small).
        let mut hole: BTreeSet<(u8, i32, i32)> =
            BTreeSet::from([(origin.deck, origin.x, origin.y)]);
        if damage_bp > 5000 {
            for d in Dir::ALL {
                let n = origin.neighbor(d);
                if occupied.contains_key(&(n.deck, n.x, n.y)) && roll_bp(&mut rng, 3000) {
                    hole.insert((n.deck, n.x, n.y));
                }
            }
        }
        for &(deck, x, y) in &hole {
            if let Some(id) = occupied.get(&(deck, x, y)) {
                out.depressurized.insert(*id);
            }
            for d in Dir::ALL {
                let n = Cell::new(deck, x, y).neighbor(d);
                if let Some(id) = occupied.get(&(n.deck, n.x, n.y)) {
                    out.depressurized.insert(*id);
                }
            }
        }
        remove_cells(topology, &hole, entities);
        // Rim: surviving neighbors get breach portals (open jagged boundary)
        // most of the time; scars + scorch decals regardless.
        let occupied_after = occupied_map(topology);
        for &(deck, x, y) in &hole {
            let hole_cell = Cell::new(deck, x, y);
            for d in Dir::ALL {
                let n = hole_cell.neighbor(d);
                if let Some(room_id) = occupied_after.get(&(n.deck, n.x, n.y)) {
                    out.damaged_cells.insert(n.key());
                    if roll_bp(&mut rng, profile.scorch_bp) {
                        out.cell_decals
                            .insert(n.key(), crate::model::decal::SCORCH_LIGHT);
                    }
                    if roll_bp(&mut rng, 6500) {
                        topology.portals.push(PortalIntent {
                            from_room: *room_id,
                            to_room: NO_ROOM,
                            from_cell: n,
                            to_cell: hole_cell,
                            state: EdgeKind::Breach,
                            exterior: true,
                        });
                    }
                }
            }
        }
        out.events.push(DamageEvent {
            kind: DamageEventKind::Breach,
            deck: origin.deck,
            origin: (origin.x, origin.y),
            radius: 1,
        });
    }
    dedup_portals(topology);
}

fn door_pos_rotation(cell: Cell, direction: Dir) -> (GridPos, u8) {
    match direction {
        Dir::North => (GridPos::new(cell.x, cell.y, cell.deck), 0),
        Dir::West => (GridPos::new(cell.x, cell.y, cell.deck), 1),
        Dir::South => (GridPos::new(cell.x, cell.y + 1, cell.deck), 0),
        Dir::East => (GridPos::new(cell.x + 1, cell.y, cell.deck), 1),
    }
}

fn dedup_portals(topology: &mut Topology) {
    let mut seen: BTreeSet<String> = BTreeSet::new();
    topology
        .portals
        .retain(|p| match Dir::between(p.from_cell, p.to_cell) {
            Some(d) => seen.insert(crate::structural::plan::edge_key(p.from_cell, d)),
            None => true,
        });
}

fn scorch_pass(
    master_seed: u64,
    attempt: u64,
    topology: &Topology,
    profile: &DamageProfile,
    out: &mut DamageOutcome,
) {
    if profile.scorch_rooms.is_empty() {
        return;
    }
    let mut rng = rng::stream(master_seed, "scorch", attempt);
    for room in &topology.rooms {
        if !profile.scorch_rooms.contains(&room.role) {
            continue;
        }
        for cell in &room.cells {
            if roll_bp(&mut rng, 4500) {
                let heavy = roll_bp(&mut rng, 4000);
                out.cell_decals.insert(
                    cell.key(),
                    if heavy {
                        crate::model::decal::SCORCH_HEAVY
                    } else {
                        crate::model::decal::SCORCH_LIGHT
                    },
                );
            }
        }
    }
}

fn seal_doors_pass(
    master_seed: u64,
    topology: &mut Topology,
    entities: &mut [EntitySpec],
    profile: &DamageProfile,
    protected_links: &[(RoomId, RoomId)],
) {
    if profile.sealed_door_bp == 0 {
        return;
    }
    for portal in topology.portals.iter_mut() {
        if portal.exterior || portal.state != EdgeKind::Door {
            continue;
        }
        if protected_links.iter().any(|&(a, b)| {
            (portal.from_room == a && portal.to_room == b)
                || (portal.from_room == b && portal.to_room == a)
        }) {
            continue;
        }
        let Some(d) = Dir::between(portal.from_cell, portal.to_cell) else {
            continue;
        };
        let key = crate::structural::plan::edge_key(portal.from_cell, d);
        let mut rng = rng::stream(master_seed, "seal", rng::key(0, &key, 0));
        if roll_bp(&mut rng, profile.sealed_door_bp) {
            portal.state = EdgeKind::Locked;
            let tag = format!("edge:{key}");
            if let Some(e) = entities.iter_mut().find(|e| e.tags.contains(&tag)) {
                e.locked = true;
                e.open = false;
                e.tags.push("sealed".into());
            }
        }
    }
}

fn body_pass(
    master_seed: u64,
    attempt: u64,
    topology: &Topology,
    entities: &mut Vec<EntitySpec>,
    next_entity_id: &mut u32,
    profile: &DamageProfile,
    damage_bp: i64,
) {
    let mut rng = rng::stream(master_seed, "bodies", attempt);
    let extra = damage_bp / 3000;
    let n = roll_range(
        &mut rng,
        profile.bodies.0 as i64,
        profile.bodies.1 as i64 + extra,
    );
    if n <= 0 {
        return;
    }
    let occupied_by_entities: BTreeSet<(u8, i32, i32)> = entities
        .iter()
        .map(|e| (e.pos.deck, e.pos.x, e.pos.y))
        .collect();
    let mut preferred: Vec<Cell> = Vec::new();
    let mut fallback: Vec<Cell> = Vec::new();
    for room in &topology.rooms {
        let target = if profile.body_rooms.contains(&room.role) {
            &mut preferred
        } else {
            &mut fallback
        };
        for &c in &room.cells {
            if !occupied_by_entities.contains(&(c.deck, c.x, c.y)) {
                target.push(c);
            }
        }
    }
    let mut placed: BTreeSet<(u8, i32, i32)> = BTreeSet::new();
    for b in 0..n {
        let pool: &[Cell] = if preferred.is_empty() {
            &fallback
        } else {
            &preferred
        };
        if pool.is_empty() {
            break;
        }
        let pick = roll_range(&mut rng, 0, pool.len() as i64 - 1) as usize;
        let cell = pool[pick];
        if !placed.insert((cell.deck, cell.x, cell.y)) {
            continue;
        }
        entities.push(EntitySpec {
            id: *next_entity_id,
            kind: EntityKind::Body,
            proto: "crew_body".into(),
            pos: GridPos::new(cell.x, cell.y, cell.deck),
            rotation: roll_range(&mut rng, 0, 3) as u8,
            locked: false,
            open: false,
            inventory: Vec::new(),
            tags: vec![format!("casualty_{b}")],
        });
        *next_entity_id += 1;
    }
}

fn fracture_pass(
    master_seed: u64,
    attempt: u64,
    topology: &mut Topology,
    entities: &mut Vec<EntitySpec>,
    next_entity_id: &mut u32,
    protected: &[RoomId],
    out: &mut DamageOutcome,
) {
    let mut rng = rng::stream(master_seed, "fracture", attempt);
    let occupied = occupied_map(topology);
    let (mut x0, mut x1) = (i32::MAX, i32::MIN);
    let (mut y0, mut y1) = (i32::MAX, i32::MIN);
    for &(_, x, y) in occupied.keys() {
        x0 = x0.min(x);
        x1 = x1.max(x);
        y0 = y0.min(y);
        y1 = y1.max(y);
    }
    if x1 - x0 < 8 {
        return; // too small to tear convincingly
    }

    let gap = roll_range(&mut rng, 1, 2) as i32;
    let jitter: Vec<i32> = (y0..=y1)
        .map(|_| roll_range(&mut rng, -1, 1) as i32)
        .collect();
    let jitter_at = |y: i32| jitter[(y - y0).clamp(0, (y1 - y0).max(0)) as usize];
    let mut cut_x = 0;
    let mut ok = false;
    for _ in 0..4 {
        cut_x = roll_range(
            &mut rng,
            (x0 + (x1 - x0) * 3 / 10) as i64,
            (x0 + (x1 - x0) * 7 / 10) as i64,
        ) as i32;
        let (mut left, mut right) = (0i64, 0i64);
        for &(_, x, y) in occupied.keys() {
            let cx = cut_x + jitter_at(y);
            if x < cx {
                left += 1;
            } else if x >= cx + gap {
                right += 1;
            }
        }
        let total = left + right;
        let balanced = total > 0 && left * 100 / total >= 25 && left * 100 / total <= 75;
        // The tear must not touch or straddle the entry/goal rooms.
        let protects = protected.iter().all(|id| {
            topology
                .rooms
                .iter()
                .find(|r| r.id == *id)
                .map(|room| {
                    let all_left = room.cells.iter().all(|c| c.x < cut_x + jitter_at(c.y));
                    let all_right = room
                        .cells
                        .iter()
                        .all(|c| c.x >= cut_x + jitter_at(c.y) + gap);
                    all_left || all_right
                })
                .unwrap_or(true)
        });
        if balanced && protects {
            ok = true;
            break;
        }
    }
    if !ok {
        return; // stay one heavily damaged piece
    }

    let gap_cells: BTreeSet<(u8, i32, i32)> = occupied
        .keys()
        .filter(|&&(_, x, y)| {
            let cx = cut_x + jitter_at(y);
            x >= cx && x < cx + gap
        })
        .copied()
        .collect();
    remove_cells(topology, &gap_cells, entities);

    // Per-room side assignment by majority; minority cells are torn away so
    // no room ever straddles the gap.
    let mut minority: BTreeSet<(u8, i32, i32)> = BTreeSet::new();
    let mut side_of: BTreeMap<RoomId, u8> = BTreeMap::new();
    for room in &topology.rooms {
        let right = room
            .cells
            .iter()
            .filter(|c| c.x >= cut_x + jitter_at(c.y) + gap)
            .count();
        let side = if right * 2 > room.cells.len() {
            1u8
        } else {
            0u8
        };
        side_of.insert(room.id, side);
        for c in &room.cells {
            let on_right = c.x >= cut_x + jitter_at(c.y) + gap;
            if (side == 1) != on_right {
                minority.insert((c.deck, c.x, c.y));
            }
        }
    }
    remove_cells(topology, &minority, entities);
    side_of.retain(|id, _| topology.rooms.iter().any(|r| r.id == *id));

    // Rim scars along the tear.
    let occupied_after = occupied_map(topology);
    for &(deck, x, y) in occupied_after.keys() {
        let cx = cut_x + jitter_at(y);
        if (x - cx).abs() <= 1 || (x - (cx + gap)).abs() <= 1 {
            let cell = Cell::new(deck, x, y);
            out.damaged_cells.insert(cell.key());
            out.cell_decals
                .insert(cell.key(), crate::model::decal::SCORCH_LIGHT);
        }
    }

    // Drift the right side apart (topology coords mutate; recompile derives
    // fresh canonical keys — no manual re-keying anywhere).
    let dx = roll_range(&mut rng, 2, 4) as i32;
    let dy = roll_range(&mut rng, 0, 2) as i32;
    let right_rooms: BTreeSet<RoomId> = side_of
        .iter()
        .filter(|(_, s)| **s == 1)
        .map(|(id, _)| *id)
        .collect();
    // Links crossing the tear cannot survive: prune portals and verticals
    // whose rooms ended up on opposite sides (jitter can leave diagonal
    // neighbors alive across the gap).
    topology.portals.retain(|p| {
        p.exterior
            || p.to_room == NO_ROOM
            || right_rooms.contains(&p.from_room) == right_rooms.contains(&p.to_room)
    });
    topology
        .verticals
        .retain(|v| right_rooms.contains(&v.from_room) == right_rooms.contains(&v.to_room));
    // Entities shift by their pre-drift side (before room coords change).
    for e in entities.iter_mut() {
        let was_right = e.pos.x >= cut_x + jitter_at(e.pos.y) + gap;
        if was_right {
            e.pos.x += dx;
            e.pos.y += dy;
        }
    }
    for room in topology.rooms.iter_mut() {
        if right_rooms.contains(&room.id) {
            for c in room.cells.iter_mut() {
                c.x += dx;
                c.y += dy;
            }
        }
    }
    for p in topology.portals.iter_mut() {
        if right_rooms.contains(&p.from_room) {
            p.from_cell.x += dx;
            p.from_cell.y += dy;
            p.to_cell.x += dx;
            p.to_cell.y += dy;
        }
    }
    for v in topology.verticals.iter_mut() {
        if right_rooms.contains(&v.from_room) {
            v.from_cell.x += dx;
            v.from_cell.y += dy;
            v.to_cell.x += dx;
            v.to_cell.y += dy;
        }
    }
    // Shift overlay keys for cells that moved.
    let occupied_final = occupied_map(topology);
    let shift_key = |key: &String| -> String {
        let parts: Vec<&str> = key.split('|').collect();
        if parts.len() != 3 {
            return key.clone();
        }
        let (Ok(deck), Ok(x), Ok(y)) = (
            parts[0].parse::<u8>(),
            parts[1].parse::<i32>(),
            parts[2].parse::<i32>(),
        ) else {
            return key.clone();
        };
        let shifted = (deck, x + dx, y + dy);
        match occupied_final.get(&shifted) {
            Some(id) if right_rooms.contains(id) => Cell::new(deck, x + dx, y + dy).key(),
            _ => key.clone(),
        }
    };
    out.cell_decals = out
        .cell_decals
        .iter()
        .map(|(k, v)| (shift_key(k), *v))
        .collect();
    out.damaged_cells = out.damaged_cells.iter().map(shift_key).collect();
    // Door tags re-derived from post-drift positions.
    for e in entities.iter_mut() {
        if e.kind != EntityKind::Door {
            continue;
        }
        let cell = Cell::new(e.pos.deck, e.pos.x, e.pos.y);
        let dir = if e.rotation == 0 {
            Dir::North
        } else {
            Dir::West
        };
        let key = crate::structural::plan::edge_key(cell, dir);
        e.tags.retain(|t| !t.starts_with("edge:"));
        e.tags.push(format!("edge:{key}"));
    }

    out.fractured = true;
    out.fragment_of = side_of.clone();
    out.fragments = vec![
        ShipFragment {
            id: 0,
            rooms: side_of
                .iter()
                .filter(|(_, s)| **s == 0)
                .map(|(id, _)| *id)
                .collect(),
            drift: (0, 0),
        },
        ShipFragment {
            id: 1,
            rooms: right_rooms.iter().copied().collect(),
            drift: (dx, dy),
        },
    ];
    out.events.push(DamageEvent {
        kind: DamageEventKind::StructuralFracture,
        deck: 0,
        origin: (cut_x, (y0 + y1) / 2),
        radius: gap as u16,
    });

    // Debris field in the widened gap.
    let mut debris_rng = rng::stream(master_seed, "debris", attempt);
    let field_x0 = cut_x - 1;
    let field_x1 = cut_x + gap + dx + 1;
    for y in y0..=(y1 + dy) {
        for x in field_x0..=field_x1 {
            if occupied_final.contains_key(&(0, x, y)) || !roll_bp(&mut debris_rng, 2500) {
                continue;
            }
            let protos: [(&str, EntityKind, u32); 4] = [
                ("hull_plate_debris", EntityKind::Debris, 50),
                ("debris_small", EntityKind::Debris, 30),
                ("cargo_crate", EntityKind::Container, 10),
                ("crew_body", EntityKind::Body, 10),
            ];
            let weights: Vec<u32> = protos.iter().map(|p| p.2).collect();
            if let Some(pi) = weighted_choice(&mut debris_rng, &weights) {
                entities.push(EntitySpec {
                    id: *next_entity_id,
                    kind: protos[pi].1,
                    proto: protos[pi].0.into(),
                    pos: GridPos::new(x, y, 0),
                    rotation: roll_range(&mut debris_rng, 0, 3) as u8,
                    locked: false,
                    open: false,
                    inventory: Vec::new(),
                    tags: vec!["debris_field".into()],
                });
                *next_entity_id += 1;
            }
        }
    }
    out.events.push(DamageEvent {
        kind: DamageEventKind::DebrisField,
        deck: 0,
        origin: ((field_x0 + field_x1) / 2, (y0 + y1) / 2),
        radius: ((field_x1 - field_x0) / 2).max(1) as u16,
    });
}
