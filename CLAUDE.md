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
| `06-final-decisions.md` | adjudicated decisions D1–D7 **as amended by Cleanse's rulings P1–P10** (P rulings override everything above them in that file) |
| `07-optimization.md` | per-aspect mobile budgets and measurement gates |
| `08-player.md` | Player v1 (P6): touch-first first person, WALK/CUE/CARRY modes, touch layout, avatars |

Open questions listed in `05`/each doc §6 need the user's decision — do not resolve them silently in code.

## Engine & commands

Godot **4.7.1** (`godot` on PATH), GDScript, Mobile renderer, Jolt physics. No package manager, no build step. `tests/**/*_probe.gd` are plain SceneTree scripts run with `-s`; `*_pair_probe.gd` need two processes and run through `tests/net/pair.sh`; `tests/run_all.sh` runs everything (CI: `.github/workflows/ci.yml`).

```bash
godot --path . --editor                 # open editor
godot --path .                          # run main scene
godot --path . res://src/levels/MainLevel.tscn   # run a specific scene
godot --path . --headless -s src/tools/rig_builder.gd   # one-shot SceneTree tool script
godot --path . --headless --import      # reimport assets (after adding to assets/) — also needed after adding a class_name
godot --path . --headless -s tests/physics/probe.gd   # physics feel probe (roll-out, cushion angle, draw/follow); prints PROBE OK
tests/run_all.sh                        # every probe + every pair probe; prints ALL PROBES OK
bash tests/net/pair.sh tests/net/campaign_pair_probe.gd   # two peers (host + client) run one pair probe; prints PAIR OK
bash src/tools/android_export.sh        # gradle debug APK (deep-link intent-filters) → build/android/ab.apk
src/tools/m0_device_run.sh --quick      # M0 phone gate (07 §9): export, adb install, fixtures, budget table
```

First-time Android: `src/tools/setup_android_toolchain.sh` (JDK 17, SDK 35, NDK r28b, 4.7.1 templates, debug keystore). Steam (PC only): `src/tools/fetch_godotsteam.sh` fetches the pinned GDExtensions into the gitignored `addons/`.

Do not hand-edit `.godot/` (editor cache) or `*.uid` / `*.import` files.

## Architecture (from 04, D7, P1–P2)

- **Mobile first.** Keep `renderer/rendering_method="mobile"`; no Forward+-only features (SSR, SDFGI, volumetric fog). Bar mood = `LightmapGI` bake + emissive + the Environment's depth fog (no fog planes, 06 P13); `viewport/hdr_2d=true` keeps the dark room from banding. Web export is out of scope.
- **One autoload: `NetManager`** (`src/core/`). `SaveManager` and `Settings` (`user://settings.cfg`) are static classes. `GameLoop`, `RoundDirector`, `EconomyManager`, `StreamManager`, `EffectManager`, `EventScheduler` are children of `MainLevel`; `PhysicsSim` lives inside the `Table` scene. No global signal bus. "New campaign" = scene reload.
- **Host-authoritative, event-based sync.** Host runs Jolt; clients dead-reckon between transmitted contact events via shared `BallMotion.advance`, interpolate only, gate presentation on the playback clock. Hand-packed `PackedByteArray`, not `MultiplayerSynchronizer` (only `PlayerSlot`s use `MultiplayerSpawner`). RPC modes/channels are tabulated in 04 §5 — match them exactly.
- **Transport enum** `{enet_direct, enet_noray, steam}`; Noray is primary (lobby code + direct punch) with our own tunnel relay as the any-NAT fallback (06 P10, `deploy/noray/tunnel.py`), Steam optional PC-only, loaded conditionally. Singleplayer = host with zero peers (`OfflineMultiplayerPeer`), never an `if singleplayer` branch.
- **One `Shot` at a time; non-shooters free-roam** and affect play through `request_world_interaction(kind, target_id, payload)` → host-validated `Effect` with `owner_peer_id`. Physics-altering Effects apply on host `PhysicsSim` first, then broadcast.
- **Effects are the only modifier path** (`Array[StatMod]`, `op ADD|MUL`); `Reward = Drink_Mult × Event_Mult`. Trick bonuses are disjoint multipliers, never summed.
- Boot scene is `Lobby.tscn`.

Planned layout (04 §4): `src/core` net/save/shared motion · `src/gameplay` Table, Ball, Bar, Camera, Prop · `src/levels` · `src/resources` `.tres` for BallType/Drink/Effect/Event/ShopItem · `src/ui` · `src/shaders` · `src/debug` NetGraph/SimDiff · `src/tools` one-shot scripts.

## Current state

M0–M7 built (2026-09-30), every milestone's code and probes on `main`; what is still open needs hardware or a user run (bottom).

- **Boot → play.** `Lobby.tscn` (`LobbyUI`: Host / Join code / Advanced IP / Solo / Resume / Steam when available) → `NetManager` (autoload: roster, seat order, `start_game`, `all_peers_ready` barrier) → `MainLevel.tscn`. Solo = `NetManager.host_solo()` on `OfflineMultiplayerPeer`. Lobby code = Noray OID (6-char Crockford); share link `http://160.191.243.188:8892/j/<code>` and `absolutebilliard://j/<code>` both open the app (gradle build injects the intent-filters, `addons/deeplink`).
- **Sync (M3).** Host strikes with `PhysicsSim.active_cue` after `shot_validator`; streams 25 B-intent / ≤21 B contact + divergence events (`BallEventCodec`, s16 fixed point), clients replay through `BallMotion.advance` 100 ms behind (`at_playback`). Balls freeze at rest and thaw at strike — anything that moves a resting ball outside a strike must thaw it first. Background/resume: `NetManager.backgrounded` + `request_full_state`. `tests/net/rpc_table_probe.gd` fails if any `@rpc` drifts from 04 §5.
- **Game (01/02/03).** `RoundDirector` (racks incl. authored N1/N5, gimmick balls bomb/split/joker/stone, call-pocket, host shot clock, shuffle, pocket radius/oscillation), `GameLoop` (Night/Round, checkpoints each Round via `SaveManager`, Endless), `EconomyManager` (Bartender Shop, camera rigs + scorer, cue specs), `StreamManager`, `EffectManager`/`EventScheduler` (drinks, events + vote, world interactions via `WorldInteractions`).
- **Player (08).** `player.gd` WALK/CUE/CARRY, `CueController` is the one `ShotIntent` source for touch (`src/ui/TouchControls`) and desktop keys; remote peers are puppets fed by 10 Hz poses.
- **UI (06 P11-P12, 08 §2.8).** One project Theme (`src/ui/theme/game_theme.tres`, drawn SVG sprites in `assets/ui/`, rebuilt by `src/tools/ui_art.py` + `build_ui_theme.gd`). `UILayer/UIRouter` keeps at most one modal open (`UIModal` / group `ui_modal`: PhaseScreen, EventVote, PauseMenu, Settings/Controls/Skins screens), owns the mouse mode, Esc and the one toast line; Player / CueController gate input on `UIRouter.blocking()`. HUD and touch widgets sit in a fixed region map that `tests/ui/ui_probe.gd` checks never overlap. The Lobby scene carries its own router for Settings / Controls / Skins.
- **Mobile (07).** `BarRoom.tscn` baked lighting (rebuild: `build_bar_room.gd` + `bake_lightmaps.sh`), `QualityManager` tiers, collision layers per 08 §2.1 (balls mask 1|2|3, player layer 4), CCD threshold derived from `TableSpec`, Android APK arm64 with compressed native libs.

Table reads as a real pool table at scale **2.0** (regulation × `TableSpec.scale`), everything derived from `REG_*` constants — no metre literal outside `TableSpec` in `src/gameplay/{table,balls,round}`. Data → pure geometry → scene split: `table_geometry.gd` → `table_builder.gd` → `table_visuals.gd`; `table.gd` only orchestrates. `Ball.is_resting` (not Jolt's `sleeping`) is what `PhysicsSim` counts toward `awake`. GameLoop keeps `round_director` typed `Node` on purpose: the economy probe injects a fake director. Debug tooling in `src/debug/` (NetGraph on F8, SimDiff) — see `src/debug/README.md`.

Relay box 160.191.243.188 runs Noray, the share page and the tunnel relay; join-by-code verified against it through the tunnel (`pair.sh tests/net/pair_probe.gd --noray [--relay-only]`, 2026-09-30).

**Open, needs the user:** direct punch over a friendly NAT unmeasured (the dev network is symmetric, every join from it is relayed); `ufw` fails on the relay box, so it has no firewall; GodotSteam not fetched (Steam API names unverified, its peer has no channels); M0 numbers on a real phone (`m0_device_run.sh`); iOS/macOS exports unverified (no Mac).
