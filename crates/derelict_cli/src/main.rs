//! Headless iteration harness for the derelict generator: renders ships as
//! ASCII (edge-walls at 2x resolution) or top-down PNG without any engine.

use clap::Parser;
use derelict_core::authoring::{compile_authored, GoldenArea, GoldenScope, StaleClass};
use derelict_core::model::{decal, EntityKind, FloorTile, WallEdge, NO_ROOM};
use derelict_core::structural::compile::DefaultModulePicker;
use derelict_core::structural::plan::{StructuralPlan, Topology, VerticalConnection};
use derelict_core::structural::validate::{validate, ValidationPolicy};
use derelict_core::{GenData, GenParams, Ship};

#[derive(Parser)]
#[command(name = "derelict_cli", about = "Derelict ship generator harness")]
struct Args {
    /// Master seed.
    #[arg(long, default_value_t = 1)]
    seed: u64,
    /// Archetype id (shuttle, corvette, freighter, frigate).
    #[arg(long, default_value = "corvette")]
    archetype: String,
    /// Intactness 0.0..=1.0 (omit to roll from seed).
    #[arg(long)]
    intactness: Option<f32>,
    /// Deck to render (default 0); use --all-decks for every deck.
    #[arg(long, default_value_t = 0)]
    deck: usize,
    #[arg(long)]
    all_decks: bool,
    /// ASCII render to stdout.
    #[arg(long, default_value_t = true)]
    ascii: bool,
    /// Write a PNG top-down render to this path.
    #[arg(long)]
    out: Option<String>,
    /// Print per-stage generation timings (runs 10 iterations).
    #[arg(long)]
    bench: bool,
    /// Render a sweep of seeds (count) as summaries only.
    #[arg(long)]
    sweep: Option<u64>,
    /// Export layout.json + gameplay_slice.json (The Synaptic Sea contract)
    /// into this directory.
    #[arg(long)]
    export_dir: Option<String>,
    /// Kit id stamped into the exported layout.
    #[arg(long, default_value = "ship_structural_v0")]
    kit_id: String,
    /// Stress sweep: every archetype x 3 intactness bands x 150 seeds
    /// (1,800 ships), all fail-closed validated. Non-zero exit on any error.
    #[arg(long)]
    stress: bool,
    /// Load, compile, and pre-damage-validate a golden_area.json. Skips generate.
    #[arg(
        long,
        value_name = "GOLDEN_AREA_JSON",
        conflicts_with_all = ["author_compile", "author_export"]
    )]
    author_validate: Option<String>,
    /// Compile a golden_area.json and dump StructuralPlan JSON plus issues. Skips generate.
    #[arg(
        long,
        value_name = "GOLDEN_AREA_JSON",
        conflicts_with_all = ["author_validate", "author_export"]
    )]
    author_compile: Option<String>,
    /// Compile a golden_area.json and write layout.json + gameplay_slice.json. Skips generate.
    #[arg(
        long,
        value_name = "GOLDEN_AREA_JSON",
        conflicts_with_all = ["author_validate", "author_compile"]
    )]
    author_export: Option<String>,
}

fn main() {
    let args = Args::parse();
    if args.author_validate.is_some()
        || args.author_compile.is_some()
        || args.author_export.is_some()
    {
        run_author(&args);
        return;
    }
    let data = GenData::default_bundle().expect("embedded content data");
    let mut params = GenParams::new(&args.archetype);
    if let Some(f) = args.intactness {
        params.intactness_override = Some((f.clamp(0.0, 1.0) * 10_000.0) as u16);
    }

    if args.stress {
        let mut failures = 0u32;
        let mut total = 0u32;
        let mut rooms_total = 0u64;
        let mut placements_total = 0u64;
        for arch in ["shuttle", "corvette", "freighter", "frigate"] {
            for (band, intact) in [("pristine", 9500u16), ("damaged", 5000), ("wrecked", 1000)] {
                for seed in 0..150u64 {
                    total += 1;
                    let mut p = GenParams::new(arch);
                    p.intactness_override = Some(intact);
                    match derelict_core::generate_ship(seed * 7 + 13, &p, &data) {
                        Ok(ship) => {
                            rooms_total += ship.room_graph.nodes.len() as u64;
                            placements_total += ship.plan.placements.len() as u64;
                        }
                        Err(e) => {
                            failures += 1;
                            println!("FAIL {arch}/{band} seed {}: {e}", seed * 7 + 13);
                        }
                    }
                }
            }
        }
        println!(
            "STRESS {}: runs={total} failures={failures} rooms={rooms_total} module_placements={placements_total}",
            if failures == 0 { "PASS" } else { "FAIL" }
        );
        std::process::exit(if failures == 0 { 0 } else { 1 });
    }

    if let Some(n) = args.sweep {
        for s in 0..n {
            let seed = args.seed + s;
            match derelict_core::generate_ship(seed, &params, &data) {
                Ok(ship) => println!("{}", summary_line(seed, &ship)),
                Err(e) => println!("seed {seed}: ERROR {e}"),
            }
        }
        return;
    }

    if args.bench {
        let mut totals: Vec<(&'static str, u128)> = Vec::new();
        let iters = 10;
        for i in 0..iters {
            let report = derelict_core::generate_ship_timed(args.seed + i, &params, &data)
                .expect("generation failed");
            for (name, us) in &report.stage_micros {
                match totals.iter_mut().find(|(n, _)| n == name) {
                    Some((_, t)) => *t += us,
                    None => totals.push((name, *us)),
                }
            }
        }
        println!("avg over {iters} seeds ({}):", args.archetype);
        let mut sum = 0u128;
        for (name, t) in &totals {
            println!("  {name:<10} {:>8.2} ms", *t as f64 / iters as f64 / 1000.0);
            sum += t;
        }
        println!(
            "  {:<10} {:>8.2} ms",
            "TOTAL",
            sum as f64 / iters as f64 / 1000.0
        );
        return;
    }

    let ship = match derelict_core::generate_ship(args.seed, &params, &data) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("generation failed: {e}");
            std::process::exit(1);
        }
    };
    print_summary(&ship, &data);

    if let Some(dir) = &args.export_dir {
        use derelict_core::structural::export::{
            to_gameplay_slice_json, to_layout_json, ExportOptions,
        };
        std::fs::create_dir_all(dir).expect("create export dir");
        let opts = ExportOptions {
            kit_id: args.kit_id.clone(),
            ..Default::default()
        };
        let layout = to_layout_json(&ship, &opts);
        let slice = to_gameplay_slice_json(&ship);
        let lp = format!("{dir}/layout.json");
        let gp = format!("{dir}/gameplay_slice.json");
        std::fs::write(&lp, serde_json::to_string_pretty(&layout).unwrap()).expect("write layout");
        std::fs::write(&gp, serde_json::to_string_pretty(&slice).unwrap()).expect("write slice");
        println!("exported {lp} and {gp}");
    }

    let decks: Vec<usize> = if args.all_decks {
        (0..ship.decks.len()).collect()
    } else {
        vec![args.deck.min(ship.decks.len() - 1)]
    };
    if args.ascii {
        for d in &decks {
            println!("\n=== deck {d} ===");
            println!("{}", render_ascii(&ship, *d));
        }
    }
    if let Some(path) = &args.out {
        let img = render_png(&ship, decks[0]);
        img.save(path).expect("failed to write png");
        println!("wrote {path}");
    }
}

#[derive(Debug)]
struct AuthorResult {
    id: String,
    plan: StructuralPlan,
    issues: Vec<String>,
    ok: bool,
}

fn run_author(args: &Args) {
    if let Some(path) = args.author_export.as_deref() {
        match author_export(path, args.export_dir.as_deref()) {
            Ok((layout, slice)) => {
                println!("exported {layout} and {slice}");
            }
            Err(e) => {
                eprintln!("{e}");
                std::process::exit(1);
            }
        }
        return;
    }
    let dump = args.author_compile.is_some();
    let path = args
        .author_compile
        .as_deref()
        .or(args.author_validate.as_deref())
        .expect("author path");
    match author_golden(path) {
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
        Ok(result) => {
            if dump {
                let payload = serde_json::json!({
                    "plan": result.plan,
                    "issues": result.issues,
                });
                println!("{}", serde_json::to_string_pretty(&payload).unwrap());
            }
            for issue in &result.issues {
                eprintln!("{issue}");
            }
            if !result.ok {
                std::process::exit(1);
            }
            if !dump {
                println!("ok {}", result.id);
            }
        }
    }
}

fn author_export(path: &str, export_dir: Option<&str>) -> Result<(String, String), String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("failed to read {path}: {e}"))?;
    let golden: GoldenArea =
        serde_json::from_str(&text).map_err(|e| format!("failed to parse {path}: {e}"))?;
    let docs = derelict_core::structural::export::layout_from_golden(&golden)?;
    let dir = match export_dir {
        Some(d) => std::path::PathBuf::from(d),
        None => std::path::Path::new(path)
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .join(&golden.id),
    };
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("failed to create {}: {e}", dir.display()))?;
    let layout_path = dir.join("layout.json");
    let slice_path = dir.join("gameplay_slice.json");
    std::fs::write(
        &layout_path,
        serde_json::to_string_pretty(&docs.layout).map_err(|e| e.to_string())? + "\n",
    )
    .map_err(|e| format!("failed to write {}: {e}", layout_path.display()))?;
    std::fs::write(
        &slice_path,
        serde_json::to_string_pretty(&docs.gameplay_slice).map_err(|e| e.to_string())? + "\n",
    )
    .map_err(|e| format!("failed to write {}: {e}", slice_path.display()))?;
    Ok((
        layout_path.to_string_lossy().into_owned(),
        slice_path.to_string_lossy().into_owned(),
    ))
}

fn author_golden(path: &str) -> Result<AuthorResult, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("failed to read {path}: {e}"))?;
    let golden: GoldenArea =
        serde_json::from_str(&text).map_err(|e| format!("failed to parse {path}: {e}"))?;
    author_golden_doc(golden)
}

fn author_golden_doc(golden: GoldenArea) -> Result<AuthorResult, String> {
    let default_kit = derelict_core::structural::export::ExportOptions::default().kit_id;
    if golden.kit_id != default_kit {
        return Err(format!(
            "kit '{}' is unavailable to the standalone CLI; use a kit-aware authoring bridge",
            golden.kit_id
        ));
    }
    let topology = golden.to_topology()?;
    let (plan, stale) = compile_authored(&topology, &DefaultModulePicker, &golden.module_overrides);
    let mut issues = Vec::new();
    for s in stale {
        let class = match s.class {
            StaleClass::Floor => "floor",
            StaleClass::Ceiling => "ceiling",
            StaleClass::Edge => "edge",
        };
        issues.push(format!(
            "stale {class} override {} -> {}",
            s.key, s.module_id
        ));
    }
    match author_policy(&golden, &topology) {
        Ok(policy) => {
            if let Err(v) = validate(&plan, &topology, &policy) {
                issues.extend(v.iter().map(ToString::to_string));
            }
        }
        Err(e) => issues.push(e),
    }
    Ok(AuthorResult {
        ok: issues.is_empty(),
        id: golden.id,
        plan,
        issues,
    })
}

fn author_policy(golden: &GoldenArea, topology: &Topology) -> Result<ValidationPolicy, String> {
    match golden.scope {
        GoldenScope::Room | GoldenScope::Area => Ok(ValidationPolicy::pre_damage(Vec::new())),
        GoldenScope::Derelict => {
            derelict_critical_path(golden, topology).map(ValidationPolicy::pre_damage)
        }
    }
}

fn derelict_critical_path(golden: &GoldenArea, topology: &Topology) -> Result<Vec<u16>, String> {
    if golden.entry_room.is_empty() || golden.goal_room.is_empty() {
        return Err("scope derelict requires both entry_room and goal_room".into());
    }
    let entry = resolve_stable_id(golden, &golden.entry_room)?;
    let goal = resolve_stable_id(golden, &golden.goal_room)?;
    let mut links = Vec::new();
    for p in &topology.portals {
        if p.from_room != NO_ROOM && p.to_room != NO_ROOM {
            links.push((p.from_room, p.to_room));
        }
    }
    for v in &topology.verticals {
        links.push(vertical_bfs_link(topology, v)?);
    }
    derelict_core::topology::room_path(entry, goal, &links).ok_or_else(|| {
        format!(
            "CriticalPathBroken: no BFS path from '{}' to '{}'",
            golden.entry_room, golden.goal_room
        )
    })
}

fn vertical_bfs_link(topology: &Topology, v: &VerticalConnection) -> Result<(u16, u16), String> {
    if v.from_room == NO_ROOM || v.to_room == NO_ROOM {
        return Err(format!(
            "vertical ({:?})-({:?}) uses reserved room 0",
            v.from_cell, v.to_cell
        ));
    }
    let from_room = topology
        .room(v.from_room)
        .ok_or_else(|| format!("vertical from_room {} does not exist", v.from_room))?;
    let to_room = topology
        .room(v.to_room)
        .ok_or_else(|| format!("vertical to_room {} does not exist", v.to_room))?;
    if !from_room.cells.contains(&v.from_cell) {
        return Err(format!(
            "vertical from_cell {:?} is not owned by room {}",
            v.from_cell, v.from_room
        ));
    }
    if !to_room.cells.contains(&v.to_cell) {
        return Err(format!(
            "vertical to_cell {:?} is not owned by room {}",
            v.to_cell, v.to_room
        ));
    }
    if v.from_cell.deck == v.to_cell.deck {
        return Err(format!(
            "vertical ({:?})-({:?}) must connect different decks",
            v.from_cell, v.to_cell
        ));
    }
    if v.from_cell.x != v.to_cell.x || v.from_cell.y != v.to_cell.y {
        return Err(format!(
            "vertical ({:?})-({:?}) must share x,y",
            v.from_cell, v.to_cell
        ));
    }
    Ok((v.from_room, v.to_room))
}

fn resolve_stable_id(golden: &GoldenArea, stable_id: &str) -> Result<u16, String> {
    golden
        .topology
        .rooms
        .iter()
        .find(|r| r.stable_id == stable_id)
        .map(|r| r.id)
        .ok_or_else(|| format!("unknown room stable_id '{stable_id}'"))
}

fn summary_line(seed: u64, ship: &Ship) -> String {
    let l = &ship.decks[0].layer;
    format!(
        "seed {seed:>4}  {:<9} {:>3}x{:<3} decks {}  intact {:>5.2}  {:?}{}  rooms {:>2}  entities {:>3}",
        ship.archetype_id,
        l.width,
        l.height,
        ship.decks.len(),
        ship.intactness as f32 / 10_000.0,
        ship.cause_of_loss,
        if ship.fractured { " FRACTURED" } else { "" },
        ship.room_graph.nodes.len(),
        ship.entities.len(),
    )
}

fn print_summary(ship: &Ship, data: &GenData) {
    println!("{}", summary_line(ship.seed, ship));
    let mut by_kind: Vec<(String, u32)> = Vec::new();
    for n in &ship.room_graph.nodes {
        let k = format!("{:?}", n.kind);
        match by_kind.iter_mut().find(|(name, _)| *name == k) {
            Some((_, c)) => *c += 1,
            None => by_kind.push((k, 1)),
        }
    }
    let rooms: Vec<String> = by_kind.iter().map(|(k, c)| format!("{k}x{c}")).collect();
    println!("rooms: {}", rooms.join(", "));
    let containers = ship
        .entities
        .iter()
        .filter(|e| e.kind == EntityKind::Container)
        .count();
    let stacks: usize = ship.entities.iter().map(|e| e.inventory.len()).sum();
    let items: u32 = ship
        .entities
        .iter()
        .flat_map(|e| e.inventory.iter())
        .map(|s| s.qty as u32)
        .sum();
    println!(
        "entities: {} total, {} containers, {} loot stacks / {} items",
        ship.entities.len(),
        containers,
        stacks,
        items
    );
    for ev in &ship.damage_events {
        println!(
            "damage: {:?} deck {} at {:?} r={}",
            ev.kind, ev.deck, ev.origin, ev.radius
        );
    }
    let depress = ship
        .room_graph
        .nodes
        .iter()
        .filter(|n| n.depressurized)
        .count();
    println!(
        "depressurized rooms: {depress}/{}",
        ship.room_graph.nodes.len()
    );
    let _ = data;
}

/// ASCII render at 2x+1 resolution so edge walls are visible:
/// even rows/cols carry edges and corners, odd/odd carry tile contents.
fn render_ascii(ship: &Ship, deck: usize) -> String {
    let layer = &ship.decks[deck].layer;
    let w = layer.width as i32;
    let h = layer.height as i32;
    let gw = (2 * w + 1) as usize;
    let gh = (2 * h + 1) as usize;
    let mut grid = vec![' '; gw * gh];

    let hedge = |e: WallEdge| match e {
        WallEdge::None => ' ',
        WallEdge::Hull => '=',
        WallEdge::Interior => '-',
        WallEdge::Doorway => '+',
        WallEdge::Breached => '%',
    };
    let vedge = |e: WallEdge| match e {
        WallEdge::None => ' ',
        WallEdge::Hull => 'H',
        WallEdge::Interior => '|',
        WallEdge::Doorway => '+',
        WallEdge::Breached => '%',
    };

    for y in 0..h {
        for x in 0..w {
            let i = (y * w + x) as usize;
            let gx = (2 * x + 1) as usize;
            let gy = (2 * y + 1) as usize;
            // Tile content.
            grid[gy * gw + gx] = match layer.floor[i] {
                FloorTile::Void => ' ',
                FloorTile::Deck => {
                    if layer.decal[i] == decal::SCORCH_LIGHT
                        || layer.decal[i] == decal::SCORCH_HEAVY
                    {
                        '*'
                    } else {
                        '.'
                    }
                }
                FloorTile::Grated => ':',
                FloorTile::DamagedDeck => '~',
            };
            // Edges (north on row above, west on col left).
            grid[(gy - 1) * gw + gx] = hedge(layer.walls[i].north);
            grid[gy * gw + gx - 1] = vedge(layer.walls[i].west);
        }
    }
    // Entities overwrite tile cells.
    for e in &ship.entities {
        if e.pos.deck as usize != deck {
            continue;
        }
        if e.kind == EntityKind::Door {
            continue; // visible as '+' edges already
        }
        let gx = (2 * e.pos.x + 1) as usize;
        let gy = (2 * e.pos.y + 1) as usize;
        if gy < gh && gx < gw {
            grid[gy * gw + gx] = match e.kind {
                EntityKind::Container => 'c',
                EntityKind::Terminal => 't',
                EntityKind::Furniture => {
                    if e.proto == "ladder" {
                        'L'
                    } else {
                        'f'
                    }
                }
                EntityKind::Body => 'b',
                EntityKind::Debris => 'x',
                EntityKind::ItemPile => 'i',
                EntityKind::Door => '+',
            };
        }
    }
    // Corners: '+' where any adjacent edge is a wall.
    for gy in (0..gh).step_by(2) {
        for gx in (0..gw).step_by(2) {
            let mut any = false;
            if gx > 0 && grid[gy * gw + gx - 1] != ' ' {
                any = true;
            }
            if gx + 1 < gw && grid[gy * gw + gx + 1] != ' ' {
                any = true;
            }
            if gy > 0 && grid[(gy - 1) * gw + gx] != ' ' {
                any = true;
            }
            if gy + 1 < gh && grid[(gy + 1) * gw + gx] != ' ' {
                any = true;
            }
            if any {
                grid[gy * gw + gx] = '+';
            }
        }
    }

    let mut out = String::with_capacity(gw * gh + gh);
    for gy in 0..gh {
        let row: String = grid[gy * gw..(gy + 1) * gw].iter().collect();
        // Trim-right for compact output.
        out.push_str(row.trim_end());
        out.push('\n');
    }
    out
}

/// Simple top-down PNG: 6px tiles, 1px wall edges.
fn render_png(ship: &Ship, deck: usize) -> image::RgbImage {
    let layer = &ship.decks[deck].layer;
    let s = 6u32;
    let w = layer.width as u32 * s;
    let h = layer.height as u32 * s;
    let mut img = image::RgbImage::from_pixel(w, h, image::Rgb([8, 8, 16]));
    let floor_color = |f: FloorTile, d: u8, room: u16| -> image::Rgb<u8> {
        match f {
            FloorTile::Void => image::Rgb([8, 8, 16]),
            FloorTile::Deck => {
                let tint = (room % 5) as u8 * 8;
                if d == decal::SCORCH_HEAVY {
                    image::Rgb([40, 32, 28])
                } else if d == decal::SCORCH_LIGHT {
                    image::Rgb([70, 60, 50])
                } else {
                    image::Rgb([100 + tint, 100 + tint, 110 + tint])
                }
            }
            FloorTile::Grated => image::Rgb([70, 80, 90]),
            FloorTile::DamagedDeck => image::Rgb([90, 70, 55]),
        }
    };
    for y in 0..layer.height as u32 {
        for x in 0..layer.width as u32 {
            let i = (y * layer.width as u32 + x) as usize;
            let c = floor_color(layer.floor[i], layer.decal[i], layer.room_id[i]);
            for py in 0..s {
                for px in 0..s {
                    img.put_pixel(x * s + px, y * s + py, c);
                }
            }
            let wall_c = |e: WallEdge| match e {
                WallEdge::Hull => Some(image::Rgb([220, 220, 235])),
                WallEdge::Interior => Some(image::Rgb([160, 160, 175])),
                WallEdge::Doorway => Some(image::Rgb([80, 180, 90])),
                WallEdge::Breached => Some(image::Rgb([200, 90, 60])),
                WallEdge::None => None,
            };
            if let Some(c) = wall_c(layer.walls[i].north) {
                for px in 0..s {
                    img.put_pixel(x * s + px, y * s, c);
                }
            }
            if let Some(c) = wall_c(layer.walls[i].west) {
                for py in 0..s {
                    img.put_pixel(x * s, y * s + py, c);
                }
            }
        }
    }
    for e in &ship.entities {
        if e.pos.deck as usize != deck || e.kind == EntityKind::Door {
            continue;
        }
        let c = match e.kind {
            EntityKind::Container => image::Rgb([230, 180, 60]),
            EntityKind::Terminal => image::Rgb([60, 200, 220]),
            EntityKind::Furniture => image::Rgb([140, 110, 80]),
            EntityKind::Body => image::Rgb([200, 60, 60]),
            EntityKind::Debris => image::Rgb([120, 120, 120]),
            EntityKind::ItemPile => image::Rgb([240, 240, 120]),
            EntityKind::Door => image::Rgb([80, 180, 90]),
        };
        let (x, y) = (e.pos.x as u32, e.pos.y as u32);
        if x < layer.width as u32 && y < layer.height as u32 {
            for py in 1..s - 1 {
                for px in 1..s - 1 {
                    img.put_pixel(x * s + px, y * s + py, c);
                }
            }
        }
    }
    let _ = NO_ROOM;
    img
}

#[cfg(test)]
mod tests {
    use super::*;

    fn airlock_path() -> String {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../derelict_core/assets/golden_areas/airlock_2x2.json")
            .to_string_lossy()
            .into_owned()
    }

    #[test]
    fn author_validate_airlock_2x2() {
        let result = author_golden(&airlock_path()).expect("load/compile airlock_2x2");
        assert!(
            result.ok,
            "airlock_2x2 must validate, issues: {:?}",
            result.issues
        );
        assert!(result.issues.is_empty());
        assert_eq!(result.id, "airlock_2x2");
        assert!(!result.plan.occupancy.is_empty());
    }

    #[test]
    fn author_load_missing_file_fails() {
        let err = author_golden("does-not-exist-golden.json").expect_err("missing file");
        assert!(err.contains("failed to read"), "{err}");
    }

    fn sample() -> GoldenArea {
        serde_json::from_str(&std::fs::read_to_string(airlock_path()).unwrap()).unwrap()
    }

    fn two_room_derelict(
        hub_deck: u8,
        vertical: derelict_core::authoring::VerticalConnectionDto,
    ) -> GoldenArea {
        let mut golden = sample();
        golden.scope = GoldenScope::Derelict;
        golden.goal_room = "hub_01".into();
        golden
            .topology
            .rooms
            .push(derelict_core::authoring::RoomSpecDto {
                id: 2,
                stable_id: "hub_01".into(),
                role: "hub".into(),
                deck: hub_deck,
                cells: vec![[0, 0], [1, 0], [0, 1], [1, 1]],
            });
        golden.topology.verticals.push(vertical);
        golden
    }

    #[test]
    fn author_validate_rejects_stale_overrides() {
        let mut golden = sample();
        golden
            .module_overrides
            .floors
            .insert("9|9|9".into(), "floor_1x1".into());
        let result = author_golden_doc(golden).unwrap();
        assert!(!result.ok, "stale override must fail closed");
        assert!(
            result
                .issues
                .iter()
                .any(|i| i.contains("stale floor override") && i.contains("9|9|9")),
            "issues: {:?}",
            result.issues
        );
    }

    #[test]
    fn author_validate_rejects_unresolved_non_default_kit() {
        let mut golden = sample();
        golden.kit_id = "missing_runtime_kit".into();
        let err = author_golden_doc(golden)
            .expect_err("CLI must not use the default picker for another kit");
        assert!(err.contains("missing_runtime_kit"), "{err}");
    }

    #[test]
    fn author_validate_rejects_malformed_vertical_links() {
        let stacked = derelict_core::authoring::VerticalConnectionDto {
            from_room: 1,
            to_room: 2,
            from_cell: [0, 0, 0],
            to_cell: [0, 0, 1],
        };
        let result = author_golden_doc(two_room_derelict(1, stacked)).unwrap();
        assert!(
            result.ok,
            "stacked vertical must validate, issues: {:?}",
            result.issues
        );

        let same_deck = derelict_core::authoring::VerticalConnectionDto {
            from_room: 1,
            to_room: 2,
            from_cell: [0, 0, 0],
            to_cell: [1, 0, 0],
        };
        let result = author_golden_doc(two_room_derelict(0, same_deck)).unwrap();
        assert!(!result.ok);
        assert!(
            result
                .issues
                .iter()
                .any(|i| i.contains("must connect different decks")),
            "issues: {:?}",
            result.issues
        );

        let unowned = derelict_core::authoring::VerticalConnectionDto {
            from_room: 1,
            to_room: 2,
            from_cell: [0, 0, 0],
            to_cell: [9, 9, 1],
        };
        let result = author_golden_doc(two_room_derelict(1, unowned)).unwrap();
        assert!(!result.ok);
        assert!(
            result
                .issues
                .iter()
                .any(|i| i.contains("not owned by room")),
            "issues: {:?}",
            result.issues
        );
    }

    #[test]
    fn author_export_airlock_2x2() {
        let dir =
            std::env::temp_dir().join(format!("derelict_author_export_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (layout, slice) =
            author_export(&airlock_path(), Some(dir.to_str().unwrap())).expect("export");
        let layout_v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&layout).unwrap()).unwrap();
        let slice_v: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&slice).unwrap()).unwrap();
        assert_eq!(layout_v["generator"]["name"], "derelict_builder");
        assert!(layout_v["portals"].as_array().unwrap().is_empty());
        assert_eq!(slice_v["objectives"][0]["id"], "airlock_01:reach_goal");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn author_export_floor_bad_module_fails() {
        let mut golden: GoldenArea =
            serde_json::from_str(&std::fs::read_to_string(airlock_path()).unwrap()).unwrap();
        golden
            .module_overrides
            .floors
            .insert("0|0|0".into(), "floor_2x1".into());
        let dir =
            std::env::temp_dir().join(format!("derelict_author_export_bad_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let bad = dir.join("bad.json");
        std::fs::write(&bad, serde_json::to_string(&golden).unwrap()).unwrap();
        let err = author_export(bad.to_str().unwrap(), Some(dir.to_str().unwrap()))
            .expect_err("FloorBadModule");
        assert!(err.contains("FloorBadModule"), "{err}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
