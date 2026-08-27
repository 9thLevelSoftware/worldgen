# Derelict WorldGen

Procedural generation of derelict spacecraft for an isometric, Project
Zomboid-style Godot game. Ships are generated on demand as players discover
them in the wild — some intact, some torn into pieces with debris fields
drifting between the fragments.


## Layout

| Path | What |
|---|---|
| `crates/derelict_core` | Pure-Rust deterministic generation pipeline. Zero engine deps. |
| `crates/derelict_cli` | Headless ASCII/PNG harness + per-stage benchmarks. The fast iteration loop. |
| `crates/derelict_godot` | Thin GDExtension bridge (`gdext` 0.5) exposing `DerelictGenerator` to GDScript. |
| `godot/` | Godot 4 project: the `addons/derelict` addon (runtime + debug viewer) and a test scene. |
| `scripts/build_windows.ps1` | Builds the Rust dll and installs it into the addon. |

## Requirements

- Rust (stable; developed on 1.97)
- Godot **4.3+** (developed against 4.6.2; 4.7.x works — `compatibility_minimum` is 4.3)

## Quick start

```powershell
# 1. Core tests (no Godot needed)
cargo test

# 2. Look at ships without an engine (default generate path)
cargo run -p derelict_cli -- --seed 12 --archetype frigate --intactness 0.3 --all-decks
cargo run -p derelict_cli --release -- --bench --archetype frigate   # ~27 ms/ship
cargo run -p derelict_cli -- --sweep 20 --archetype freighter        # summaries
cargo run -p derelict_cli -- --seed 17 --archetype corvette --export-dir target/export --kit-id ship_structural_v0
cargo run -p derelict_cli --release -- --stress

# 3. Validate / compile / export an authored golden area (skips generate)
cargo run -p derelict_cli -- --author-validate crates/derelict_core/assets/golden_areas/airlock_2x2.json
cargo run -p derelict_cli -- --author-compile crates/derelict_core/assets/golden_areas/airlock_2x2.json
cargo run -p derelict_cli -- --author-export crates/derelict_core/assets/golden_areas/airlock_2x2.json --export-dir target/export/airlock_2x2

# 4. Build the extension and open the Godot project
powershell -File scripts\build_windows.ps1
# then open godot/project.godot in the Godot editor and press F5

# 5. Run every standalone builder headless check
powershell -File scripts\test_builder.ps1 -SynapticSeaRoot ..\the-synaptic-sea
```

`test_builder.ps1` resolves Godot from `-GodotPath`, `GODOT_PATH`, or `PATH`,
builds and installs the builder GDExtension, then fails fast across the guided
workspace, hazards, module picker, prop palette, and structural preview checks.
Use `-SkipBuild` only when an open local Godot editor already holds the current
builder DLL; CI always performs a clean build.

The generate path also accepts `--out <path>` for a top-down PNG, `--deck <n>`
or `--all-decks`, `--sweep <count>`, and `--bench`. `--archetype` accepts the
embedded shuttle, corvette, freighter, and frigate definitions.

`--author-validate`, `--author-compile`, and `--author-export` are flat clap
flags, mutually exclusive with each other. When any is set they replace the
generate path (`--seed`, `--archetype`, `--stress`, …). They load a
`golden_area.json`, adapt it to Topology, compile with `DefaultModulePicker`,
and run pre-damage validation: `pre_damage([])` for `scope` room/area;
derelict scope requires both `entry_room` and `goal_room` and a BFS path
between them. `--author-validate` exits 0 on success and prints issues on
stderr on failure. `--author-compile` dumps plan JSON plus issues and still
exits non-zero on failure. `--author-export` writes `layout.json` (schema
1.2.0) and `gameplay_slice.json` (schema 1.1.0) into `--export-dir` (or
`<golden-dir>/<id>/` when `--export-dir` is omitted). Export is fail-closed:
`FloorBadModule`, `ReachabilityBroken`, and unresolved `entry_room` /
`goal_room` exit non-zero. A committed airlock fixture lives at
`crates/derelict_core/assets/golden_areas/airlock_2x2/`.

The Synaptic Sea loads those two files with `GeneratedShipLoader.load_from_paths`:

```gdscript
var loader := GeneratedShipLoader.new()
var err: String = loader.load_from_paths(
    "res://data/procgen/golden/airlock_2x2/layout.json",
    "res://data/procgen/golden/airlock_2x2/gameplay_slice.json"
)
if not err.is_empty():
    push_error(err)
```

`load_from_documents` is the in-memory equivalent (parsed dictionaries). Room
ids in the exported documents are golden `stable_id` strings (not numeric
`RoomId`s). Exterior doors stay plan edges — `layout.portals` is interior-only.
Loot `contents` are written for explicit stacks; the game honors them after
the Synaptic Sea follow-up that copies `contents` into loot specs.

The main scene is the **debug viewer**: seed entry, ship class dropdown,
intactness slider, deck switching, room-graph/damage overlay, plus a
walkable test player (WASD, F interact/loot, E/Q climb ladders between
decks, bump closed doors to open them, MMB pan, wheel zoom).

Headless verification without opening the editor:

```powershell
godot --headless --path godot -s tests/smoke.gd
```

## Generation pipeline (`derelict_core`)

Nine fixed-order pure stages, each drawing from its own named RNG stream
(`stream(master_seed, stage_tag, sub)`), so changing one stage never
reshuffles another and per-container loot never depends on iteration order:

1. **Archetype** — data-driven RON (`assets/archetypes/*.ron`): shuttle,
   corvette, freighter, frigate. New classes need no Rust changes.
2. **Hull** — mirrored polyomino growth inside an elliptical envelope
   (integer math only); upper decks are eroded, guaranteed-nested subsets.
3. **Rooms** — constrained BSP; required rooms placed by bow/stern
   preference scoring, airlocks pinned to the hull boundary.
4. **Corridors** — MST over room centroids + seeded loop-back edges;
   L-paths with BFS fallback; rooms split by carving are relabeled.
5. **Doors & shafts** — every room guaranteed reachable (BFS repair);
   exterior airlock doors; vertical ladder shafts aligned across decks.
6. **Furnishing** — per-room-type rules (`furnishing_rules/default.ron`):
   placement strategies, lock chances, containers placed empty.
7. **Story** — a cause-of-loss (reactor breach, pirates, plague, ...) turned
   into damage-bias weights, body placement, loot modifiers.
8. **Damage** — intactness-gated (0..=10000 bp): CA-eroded hull breaches,
   scorch, sealed doors, bodies; below 3500 bp the ship **fractures** along a
   jagged cut, the pieces are baked apart into an enlarged grid, and the gap
   fills with a deterministic debris field (crates in the debris are
   lootable).
9. **Loot** — `loot_tables/default.ron` per room type; per-container RNG
   streams keyed by entity id.

### Determinism contract

`generate_ship(seed, params)` at a given `GENERATOR_VERSION` is byte-identical
on every platform: PCG RNG only (via `rng::stream`), `BTreeMap`/stable
iteration everywhere it matters, no floats in decision-affecting math
(fixed-point basis points), golden blake3 hashes in CI
(`tests/golden/hashes.txt`). If you intentionally change generation output:
bump `GENERATOR_VERSION` in `model.rs` and run
`UPDATE_GOLDEN=1 cargo test -p derelict_core --test golden` in the same commit.

## Godot API

```gdscript
var gen = ClassDB.instantiate("DerelictGenerator")
var seed: int = gen.derive_site_seed(world_seed, world_x, world_y)  # co-op-safe
var id: int = gen.generate_async(seed, {"archetype_id": "frigate"})
# poll from _process:
var ship = gen.poll_async(id)      # null while running, Dictionary when done
```

Ship dictionaries carry per-deck `PackedInt32Array` tile layers (`floor`,
`wall_north`, `wall_west`, `room_id`, `decal` — walls live on tile **edges**,
PZ-style), plus `rooms`, `edges`, `entities`, `damage_events`, `fragments`.

Higher-level: drop a `DerelictSite` node in your world, set
`world_seed/world_x/world_y/archetype_id`, call `discover()` — it generates
in the background, instantiates a `DerelictShipNode` (TileMapLayers + budgeted
entity spawning, no frame hitches), and applies any saved mutation diff.

## Persistence & co-op

The base ship is never saved. `ShipPersistence` stores only the mutation
diff (doors opened/locked, container inventories, removed entities) as JSON
under `user://derelicts/<site_id>.json`, keyed by stable entity ids; loads
regenerate from seed and re-apply the diff. Unknown entity ids after a
generator upgrade are skipped, never fatal.

Co-op model (host-authoritative): replicate `(seed, params,
generator_version)` — a few bytes — and each client regenerates the identical
ship (`derive_site_seed` is discovery-order independent). Replicate mutations
by sending the same diff dict through your RPC layer and calling
`persistence.apply(ship_node)`; save/load and network sync share one code
path. The Rust side mirrors this with `ShipMutationDiff` + `apply_diff` for
future server-side validation.

## Swapping in real art

`PlaceholderTiles.gd` builds the TileSet procedurally; replace it with a
drawn TileSet keeping atlas coords (source 0 x = floor id, source 1 x =
decal id). `WallLayer.gd` draws walls as extruded quads from the edge data —
replace with autotiled wall sprites when art exists. Entity visuals map by
`kind`/`proto` in `EntityNode.gd`; register real scenes per proto there.
