# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Source of truth: `docs/plan/`

The design docs are authoritative. Code is implemented **from** them, never the other way round. Before touching any system, read the owning doc; if code and doc disagree, the doc wins unless the user rules otherwise — then update the doc in the same change.

| Doc | Owns |
|---|---|
| `00-contract.md` | pitch, **shared vocabulary** (use these names exactly: `Ball`, `BallType`, `Shot`, `Turn`, `Round`, `Night`, `Quota`, `Cash`, `Stream`, `Viewers`, `Camera`, `Drink`, `Effect`, `Event`, `TrickShot`), doc template |
| `01-physics-table-balls.md` | Jolt `RigidBody3D` settings, cue, BallType tiers, TrickShot detection, random drop, physics test fixtures |
| `02-economy-loop.md` | Night/Round/Quota, income sheet, Stream/Viewers/Camera scoring, Bartender Shop catalog |
| `03-bar-drinks-events.md` | typed `StatMod`/`Effect` schema, Drinks, crew-chosen Events, free-roam world interactions |
| `04-architecture-netcode.md` | project layout, scene tree, autoloads, transport, RPC/channel table, `SaveProfile` |
| `05-index.md` | cross-module signal map, open questions, review checklist |
| `06-final-decisions.md` | adjudicated decisions D1–D7 **as amended by Cleanse's rulings P1–P5** (P rulings override everything above them in that file) |
| `07-optimization.md` | per-aspect mobile budgets and measurement gates |

Open questions listed in `05`/each doc §6 need the user's decision — do not resolve them silently in code.

## Engine & commands

Godot **4.7.1** (`godot` on PATH), GDScript, Mobile renderer, Jolt physics. No package manager, no build step, no test runner — `tests/**/*_probe.gd` are plain SceneTree scripts run with `-s`; codec round-trip and save migration fixtures are still planned in 04 §4.

```bash
godot --path . --editor                 # open editor
godot --path .                          # run main scene
godot --path . res://src/levels/MainLevel.tscn   # run a specific scene
godot --path . --headless -s src/tools/rig_builder.gd   # one-shot SceneTree tool script
godot --path . --headless --import      # reimport assets (after adding to assets/) — also needed after adding a class_name
godot --path . --headless -s tests/physics/probe.gd   # physics feel probe (roll-out, cushion angle, draw/follow); prints PROBE OK
```

Do not hand-edit `.godot/` (editor cache) or `*.uid` / `*.import` files.

## Architecture (from 04, D7, P1–P2)

- **Mobile first.** Keep `renderer/rendering_method="mobile"`; no Forward+-only features (SSR, SDFGI, volumetric fog). Bar mood = `LightmapGI` bake + emissive + fog plane. Web export is out of scope.
- **One autoload: `NetManager`** (`src/core/`). `SaveManager` is a static class. `GameLoop`, `RoundDirector`, `EconomyManager`, `StreamManager`, `EffectManager`, `EventScheduler` are children of `MainLevel`; `PhysicsSim` lives inside the `Table` scene. No global signal bus. "New campaign" = scene reload.
- **Host-authoritative, event-based sync.** Host runs Jolt; clients dead-reckon between transmitted contact events via shared `BallMotion.advance`, interpolate only, gate presentation on the playback clock. Hand-packed `PackedByteArray`, not `MultiplayerSynchronizer` (only `PlayerSlot`s use `MultiplayerSpawner`). RPC modes/channels are tabulated in 04 §5 — match them exactly.
- **Transport enum** `{enet_direct, enet_noray, steam}`; Noray is primary, Steam optional PC-only, loaded conditionally. Singleplayer = host with zero peers (`OfflineMultiplayerPeer`), never an `if singleplayer` branch.
- **One `Shot` at a time; non-shooters free-roam** and affect play through `request_world_interaction(kind, target_id, payload)` → host-validated `Effect` with `owner_peer_id`. Physics-altering Effects apply on host `PhysicsSim` first, then broadcast.
- **Effects are the only modifier path** (`Array[StatMod]`, `op ADD|MUL`); `Reward = Drink_Mult × Event_Mult`. Trick bonuses are disjoint multipliers, never summed.
- Boot scene is `Lobby.tscn`.

Planned layout (04 §4): `src/core` net/save/shared motion · `src/gameplay` Table, Ball, Bar, Camera, Prop · `src/levels` · `src/resources` `.tres` for BallType/Drink/Effect/Event/ShopItem · `src/ui` · `src/shaders` · `src/debug` NetGraph/SimDiff · `src/tools` one-shot scripts.

## Current state

M1 local sim (2026-09-21): boot is `Lobby.tscn` → Solo → `NetManager.host()` installs `OfflineMultiplayerPeer` → `MainLevel.tscn`, whose `main_level.gd` starts the campaign. `MainLevel` children: `RoundDirector` (rack drop via seeded Poisson-disk `rack_dropper.gd`, shot boundary off `PhysicsSim.shot_started`/`all_resting`, `ContactLog`, `TrickDetector` — 5 disjoint tricks, foul + kitchen respawn, OFF_TABLE by bounds, wedged-cue respawn), `GameLoop` (Night/Round state machine, 120 s timer, shot budget, untimed Intermission, reckoning, Buyout on Night 5), `EconomyManager` (02 §3.2 with Camera_Mult/Event_Mult pinned 1.0 until M5/M6), `StreamManager` (viewers/hype/tips; buffers `ball_potted` and applies after Economy reads `viewer_scalar()`), `UILayer/HUD`. `NightConfig` ×5 in `src/resources/nights/`. `DemoRack` stays in the scene with `enabled = false` (debug presets only). `CueController.gate` lets `RoundDirector` restrict strikes to the cue ball between shots. Signal names follow 02 §5 verbatim; `round_ended` reasons `timer | cleared | shots` (`stuck` retired).

Headless checks (all must print their OK): `tests/core/lobby_probe.gd` (C1), `tests/core/main_level_probe.gd` (integration), `tests/round/round_probe.gd` (C3–C5), `tests/economy/economy_probe.gd` (C6), `tests/physics/probe.gd`, `tests/physics/geometry_probe.gd`. GameLoop keeps `round_director` typed `Node` on purpose: the economy probe injects a fake director.

Table (v0.0.3-beta) reads as a real pool table at scale **2.0** (regulation × `TableSpec.scale`), everything derived from `REG_*` constants — no metre literal outside `TableSpec` in `src/gameplay/{table,balls,round}`. Data → pure geometry → scene split: `table_geometry.gd` → `table_builder.gd` → `table_visuals.gd`; `table.gd` only orchestrates. `Ball.is_resting` (not Jolt's `sleeping`) is what `PhysicsSim` counts toward `awake`; a pocketed ball reports resting when it freezes. Debug tooling in `src/debug/` — see `src/debug/README.md`. `src/gameplay/player/` is a placeholder first-person walker — **Player design is deferred**, treat it as a black box. Not built yet: M0 mobile perf spike (needs the phone), M2+ netcode, Effects/Drinks/Events, Shop, cameras, SaveProfile, gimmick balls, authored racks.
