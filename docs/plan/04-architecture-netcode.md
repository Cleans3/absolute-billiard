# 04 Architecture & Netcode

*Rewritten against 06 D2 + D7 as amended by Cleanse's P1–P3. Mobile first; Player still a black box.*

## 1. Purpose
Defines the Godot 4.7 project layout, module boundaries, and the multiplayer model for Absolute Billiard: host-authoritative simulation, event-based ball sync, and a swappable transport so a phone and a PC can sit in the same friends-only lobby.

## 2. Concepts & data model

### 2.1 Platform matrix
Mobile is the design target; everything else is the same build with a different export preset.

| Platform | Ship | Why |
|---|---|---|
| **Android** | **yes — primary** | The target. Touch cue, Mobile renderer, ENet/UDP available, `.apk`/`.aab` export is free. |
| **iOS** | **yes — primary** | Same target class. Costs an Apple account and TestFlight for playtests; no dynamic code loading, which is fine because nothing PC-only ships here. |
| **Windows** | yes | Steam + itch. The only preset that enables the GodotSteam peer. |
| **Linux** | yes | Same export template cost as Windows; also the box the Noray relay is developed against. |
| **macOS** | yes, after iOS | Notarisation reuses the Apple account iOS already paid for. Low priority, itch only. |
| **Web** | **no** | Three independent blockers: browsers cannot open UDP sockets, so ENet is unavailable and the whole transport layer would need a second WebRTC path with its own signalling; 16 `RigidBody3D` on Jolt at 240 Hz in single-threaded wasm is outside the mobile budget we are already fighting for; and threaded web builds need cross-origin-isolation headers we do not control on itch. Revisit post-1.0 only as a spectator client. |

### 2.2 Renderer and bar mood
`project.godot` already reads `renderer/rendering_method="mobile"` and `config/features=PackedStringArray("4.7", "Mobile")`. Both correct — **no change**, and no `.mobile` feature-tag override: one renderer on every platform means one lighting look to tune instead of two.

Checked against 4.7's renderer comparison: Mobile has **no** SDFGI, VoxelGI, SSIL, SSAO, SSR, volumetric fog, TAA or FSR2 — all Forward+ only. It **does** have `LightmapGI`, `ReflectionProbe` (8 per mesh), depth/height fog, MSAA and CompositorEffects. So the dim-bar mood is bought statically:

| Want | Technique |
|---|---|
| Dark room, warm pools of light | `LightmapGI` bake. All bar geometry static; ambience lights `bake_mode = STATIC` so they cost nothing at runtime. |
| Neon, jukebox, TV, bottle shelf, pocket rims | Emissive materials. Emission feeds the lightmap bake, so a neon sign lights the wall around it for free. |
| The one light that must move | Table lamp: single `SpotLight3D`, `bake_mode = DYNAMIC`, shadows on, tight range. Budget is **one shadow-casting light** `[tune]`. |
| Wet bar top, chrome, cue tips | Baked `ReflectionProbe` per room zone (bar, table, booth) instead of SSR. Mobile allows 8 per mesh, so three zones is comfortable. |
| Haze | `WorldEnvironment` depth fog (`fog_enabled`, low `fog_density`, warm `fog_light_color`) plus a hand-placed **fog plane**: 2–3 camera-facing quads in the lamp cone, unshaded additive shader, scrolling noise, edges faded by view angle rather than a depth-texture read. ~3 draw calls, no framebuffer sampling. |
| Neon bloom | Glow on, low quality, additive `[tune]` — measure at M0; it is the first thing cut if the frame budget slips. |
| Clean ball silhouettes | MSAA 2× `[tune]`. There is no temporal AA to lean on here, so edges are paid for in MSAA or not at all. |

### 2.3 Transport
`NetManager` (the only autoload) owns exactly one `MultiplayerPeer` and hands it to `multiplayer.multiplayer_peer`. Nothing else in the codebase constructs a peer. Transport is an enum:

| `Transport` | Peer | Used for |
|---|---|---|
| `enet_direct` | `ENetMultiplayerPeer.create_server/create_client` | LAN, dev, two instances on one machine, "advanced" IP entry. |
| `enet_noray` | Same peer, socket pre-punched via a Noray handshake | **Primary path.** Every internet game, mobile and PC. |
| `steam` | GodotSteam `SteamMultiplayerPeer` | **Optional, PC only.** Steam invites and overlay for people who bought it there. |

Cross-play is mobile↔PC over `enet_noray`; the `steam` peer is a convenience path between two Steam clients, never a requirement. The Steam extension is loaded conditionally (`OS.has_feature("pc")` and the addon present), so a phone build never references it.

**Noray.** Self-hosted, open source (foxssake/noray), one small VPS: a TCP control port for registration and a UDP port for hole-punching with relay fallback `[tune]`. Host registers and receives an OID; a joiner asks Noray to connect to that OID; both sides punch, then hand the *same local UDP port* to ENet — this is what `create_client(address, port, channel_count, in_bw, out_bw, local_port)`'s `local_port` argument exists for. Relay is the fallback when punching fails, and costs the host's uplink only for that session. Config lives in `deploy/noray/.env` (never committed); the client's default relay address is a plain field in `net_config.tres`, so a fork points at its own relay by editing one resource.

**Invites.** No platform friend graph is assumed, because there isn't one on mobile.
- Host creates a lobby → Noray returns an OID → `NetManager` derives a **6-character lobby code** in Crockford base32 (no I/L/O/U, case-insensitive): ~1.07 billion codes, readable aloud, typeable on a phone keyboard.
- The same code is wrapped in a **share link** `https://<relay-host>/j/AB3K7Q`, which the OS share sheet sends over any chat app. Opening it on a device with the game installed deep-links straight into the join; without the game it is a download page.
- Deep-link plumbing: Android `<intent-filter>` in a custom Gradle build, iOS URL scheme / Universal Link in the plist. Godot's API for *reading back* the launch URL on mobile is the one piece not confirmed — see §6.
- Steam invites remain a fourth entry point on PC and resolve to the same lobby code.

### 2.4 Roles and sync model
**Host** owns the truth: Jolt sim, `Cash`, `Night`, `Round`, `Effect` timers, `Viewers`. **Clients** send intents and render. **Host migration: skipped** — but the checkpoint broadcast (§2.6) removes the reason people ask for it.

Balls move piecewise: ballistic between contacts, discontinuous at them. So the wire carries **contact events**, not snapshots.

- Host's `PhysicsSim` logs every contact (`contact_monitor` + `max_contacts_reported`, rail shapes carry `rail_id` metadata per D1) and emits `(ball_id, tick, pos, lin_vel, ang_vel)` **after** the impulse resolves.
- Clients **dead-reckon** between events with a shared pure function `BallMotion.advance(state, dt)` — same rolling-resistance model as the host's `_integrate_forces`, no Jolt on the client. Between two events the reconstruction is exact, not approximate; determinism is never needed because every discontinuity is transmitted.
- **Interpolate only, never extrapolate.** The client renders at `playback_tick = host_tick − interp_delay`, so every event it needs has already arrived. Extrapolating near a cushion is how you render a ball through a rail.
- A **2 Hz full-state heartbeat** corrects drift and re-seats a client that missed a packet or joined mid-shot.
- **Presentation is gated on the playback clock, not on packet arrival.** `shot_resolved` reaches the client ~100 ms before the client has finished watching the shot; it is queued and the `+500!` popup, the pot sound and the cash tick fire when `playback_tick` passes the potting event. Without this the score appears before the ball drops.

Events are **hand-packed** into a `PackedByteArray`, not pushed through `MultiplayerSynchronizer` — the synchroniser samples state on a timer, which is the snapshot model we just rejected. Layout per event: `ball_id u8 | tick_offset u16 | pos 3×f16 | lin_vel 3×f16 | ang_vel 3×f16` = **21 bytes**; a frame prefixes `shot_id u16 | base_tick u32 | count u8`. A 40-contact break is under 1 KB for the whole shot. `MultiplayerSpawner` *is* used, but only for `PlayerSlot`s (§4).

### 2.5 Channels
`transfer_channel 0` is internally three ENet channels (one per transfer mode), so channel 0 traffic never blocks the others by default. We still split explicitly:

| Ch | Carries | Why |
|---|---|---|
| 0 | Godot internals, `MultiplayerSpawner` replication | Leave it alone. |
| 1 | Shot intents, contact events (**reliable**) | Sparse and each one unrecoverable if lost — a dropped contact event corrupts dead reckoning forever. Reliability is cheap at ~40 packets per shot. |
| 2 | Heartbeat, viewer count, player poses (**unreliable_ordered**) | Redundant and frequent; a late one is worse than a lost one. |
| 3 | Session, economy, effects, saves (**reliable**) | Must not be blocked behind a sim burst. |

Allocate `channel_count = 8` in `create_server` / `create_client` for headroom.

### 2.6 Save data
`SaveProfile` is JSON, under 1 KB, written by `SaveManager` (a static class — **not** an autoload).

```json
{
  "save_version": 3,
  "crew_cash": 1500,
  "current_night": 3,
  "round_index": 2,
  "quota_target": 1350,
  "unlocked": { "ball_types": ["red","gold","bomb"], "cameras": ["cam_basic"], "cue": ["spin_2"] },
  "persistent_unlocks": ["drink_whiskey"],
  "seed": 884213
}
```

`save_version` gates migration: on load, an older version runs through `SaveManager.migrate(profile)`; an unknown newer version refuses and says so rather than silently dropping fields.

**The whole profile is broadcast to every peer at each `Round` end** (`push_save_checkpoint`). Each client writes it to `user://checkpoints/<lobby>.json`. If the host's phone dies, any friend re-hosts from the last checkpoint and the crew loses one Round, not the campaign. This is not host migration — the session ends, everyone re-lobbies — it just makes that cheap.

Local settings live in a separate file and are never networked. `Cash` is crew-shared per 00's pitch; there is no per-client purse (closes D2's open question).

## 3. Rules/formulas
| Knob | Value |
|---|---|
| Lobby size | `4` players max, no random matchmaking |
| Physics tick (host) | `240 Hz [tune]`, fallback `120 Hz + CCD` if M0 fails |
| Contact-event send rate | coalesced per tick, flushed at `30 Hz [tune]` only while a shot is live (07 §3) |
| Heartbeat | `2 Hz` always, including idle |
| Interpolation delay | `100 ms [tune]` = 24 host ticks at 240 Hz |
| Bandwidth ceiling | `16 KB/s [tune]` out per client — a tenth of the old snapshot budget, and it must stay there for mobile data |
| Reconstruction tolerance | client ball position within `5 mm [tune]` of host at every tick (M3 gate) |
| Lobby code | 6 chars, Crockford base32, ~1.07e9 space |
| Checkpoint broadcast | every `Round` end |
| Connection timeout | `10 s [tune]`, then peer dropped and the shot resolves without them |

## 4. Godot implementation sketch

### Project layout
```text
src/
├── core/            NetManager.gd (autoload) · Transport.gd · LobbyCode.gd
│                    SaveManager.gd (static) · BallMotion.gd (shared dead-reckoning)
├── gameplay/        Table.tscn (contains PhysicsSim.gd) · Ball.tscn · BallEventCodec.gd
│                    Bar.tscn · Camera.tscn · Prop.tscn
├── levels/          Lobby.tscn (boot scene) · MainLevel.tscn
├── resources/       BallType/ · Drink/ · Effect/ · Event/ · ShopItem/ · net_config.tres
├── ui/              LobbyUI.tscn · StreamUI.tscn · ShopUI.tscn · HUD.tscn
├── shaders/         fog_plane.gdshader · neon.gdshader
├── debug/           NetGraph.tscn · SimDiff.gd (M3 reconstruction check)
└── tools/           bake_lightmaps.gd · pack_release.sh
deploy/noray/        docker-compose.yml · .env.example
tests/               physics fixtures (D1) · codec round-trip · migration
```

Boot scene changes from `MainLevel.tscn` to **`Lobby.tscn`**. Singleplayer is not a separate mode: it is **a host with zero peers** — `Lobby.tscn`'s "Solo" button calls the same `host()` path, `NetManager` installs an `OfflineMultiplayerPeer`, and every RPC below still fires locally through `call_local`. No branch anywhere else in the codebase says `if singleplayer`.

### Autoloads
**One.** `NetManager` (`src/core/NetManager.gd`) — owns the `MultiplayerPeer`, the transport enum, the lobby code, the peer roster, and checkpoint broadcast. It is the only thing that must outlive a scene change. `SaveManager` is a static class. 01's `Signals.gd` global bus is deleted; session nodes emit their own signals and are found by direct path.

### Scene tree
```text
Lobby.tscn                     — boot: host / join by code / solo / settings
MainLevel.tscn
 ├── GameLoop                  — Night/Round state machine
 ├── RoundDirector             — shot boundaries, turn order, Round timer
 ├── EconomyManager            — Cash, Quota, payouts
 ├── StreamManager             — Viewers, camera scoring
 ├── EffectManager             — active Effects, owner_peer_id, expiry
 ├── EventScheduler            — brokers the crew's pre-Round hazard choice (D6: chosen, not rolled)
 ├── Table                     — PhysicsSim.gd lives here, plus Ball instances
 ├── PlayerSpawner             — MultiplayerSpawner, spawn_path=PlayerSlots
 │    └── PlayerSlots/         — one PlayerSlot per peer (Player module: black box)
 ├── Bar / Cameras / Props     — free-roam interaction targets
 └── UILayer
```
"New campaign" is a scene reload, so no session node needs a reset path.

## 5. Interfaces to other modules

### RPC table
`@rpc(mode, sync, transfer_mode, channel)`. **A** = all peers, **1** = `rpc_id` back to the sender only.

| RPC | Node | Dir | mode | sync | transfer | ch |
|---|---|---|---|---|---|---|
| `request_shot(dir, power, spin)` | PhysicsSim | C→H | `any_peer` | `call_remote` | `reliable` | 1 |
| `shot_rejected(reason)` | PhysicsSim | H→1 | `authority` | `call_remote` | `reliable` | 1 |
| `shot_started(shot_id, shooter_id, base_tick)` | PhysicsSim | H→A | `authority` | `call_local` | `reliable` | 1 |
| `push_contact_events(shot_id, base_tick, blob)` | PhysicsSim | H→A | `authority` | `call_remote` | `reliable` | 1 |
| `push_heartbeat(tick, blob)` | PhysicsSim | H→A | `authority` | `call_remote` | `unreliable_ordered` | 2 |
| `shot_resolved(shot_id, shooter_id, end_tick, raw_points, trick_ids, foul)` | RoundDirector | H→A | `authority` | `call_local` | `reliable` | 3 |
| `round_state(round_index, phase, time_left)` | RoundDirector | H→A | `authority` | `call_local` | `reliable` | 3 |
| `update_cash(absolute_balance)` | EconomyManager | H→A | `authority` | `call_local` | `reliable` | 3 |
| `update_viewers(count)` | StreamManager | H→A | `authority` | `call_remote` | `unreliable_ordered` | 2 |
| `apply_effect(effect_id, owner_peer_id, target_id, end_tick)` | EffectManager | H→A | `authority` | `call_local` | `reliable` | 3 |
| `apply_event(event_id, round_index)` | EventScheduler | H→A | `authority` | `call_local` | `reliable` | 3 |
| `request_world_interaction(kind, target_id, payload)` | MainLevel | C→H | `any_peer` | `call_remote` | `reliable` | 3 |
| `world_interaction_applied(peer_id, kind, target_id, payload)` | MainLevel | H→A | `authority` | `call_local` | `reliable` | 3 |
| `world_interaction_rejected(kind, reason)` | MainLevel | H→1 | `authority` | `call_remote` | `reliable` | 3 |
| `push_save_checkpoint(save_version, blob)` | NetManager | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `push_player_pose(blob)` | PlayerSlot | any→A | `any_peer` | `call_remote` | `unreliable_ordered` | 2 |

`update_cash` carries the **absolute** balance, never a delta — a lost or reordered delta desyncs the crew purse permanently, and the payload is 8 bytes either way. `update_viewers` is display-only (the host computes income from its own value), so losing one costs a frame of a number.

### Free-roam world interaction (P2)
Non-shooters roam the bar. Every one of those interactions is one RPC pair, and 04 owns only the envelope — the `kind` registry is a black box filled in by 01/02/03 and the Player pass:

`request_world_interaction(kind: StringName, target_id: int, payload: Dictionary)`

| `kind` | Target | Host validates | Owned by |
|---|---|---|---|
| `bar_buy` / `bar_serve` | shop item / peer | proximity to bar, `Cash`, cooldown | 02 shop (P3), 03 Effect |
| `camera_grab` / `camera_place` | Camera id | proximity, not already held | 02 camera scoring |
| `prop_use` | stool, jukebox, light switch | proximity, cooldown | 03 Effect |
| `table_bump` | table | proximity, per-Round budget, shot is live | 03 `table_tilt` Effect |

The host is the only validator; a rejected request comes back as `world_interaction_rejected` and the client rolls back its optimistic animation. `request_drink_purchase` from the old draft is gone — under P3 the bartender NPC is the shop, so buying a drink is `bar_buy`. Every applied interaction becomes an `Effect` with `owner_peer_id` (D6), and physics-altering Effects are applied to the authoritative `PhysicsSim` first, then broadcast; clients never simulate an alteration locally.

### Shot sequence
```mermaid
sequenceDiagram
    participant S as Shooter client
    participant I as Idle client
    participant H as Host
    participant P as PhysicsSim on host

    Note over I,H: idle clients get only the 2 Hz heartbeat between shots
    S->>H: request_shot(dir, power, spin) [ch1 reliable]
    H->>H: validate: is shooter, balls at rest, power in range
    alt rejected
        H-->>S: shot_rejected reason=not_your_turn [ch1]
    else accepted
        H->>P: apply_impulse()
        H-->>S: shot_started(shot_id, shooter_id, base_tick) [ch1]
        H-->>I: shot_started(...) [ch1]
        I->>H: request_world_interaction table_bump [ch3]
        H->>H: validate proximity + budget
        H->>P: apply table_tilt Effect
        H-->>S: apply_effect(table_tilt, owner=I) [ch3]
        H-->>I: apply_effect(table_tilt, owner=I) [ch3]
        loop every 50 ms while balls move
            P-->>H: contact log since last batch
            H-->>S: push_contact_events(shot_id, base_tick, blob) [ch1 reliable]
            H-->>I: push_contact_events(...) [ch1 reliable]
        end
        S->>S: dead-reckon + render at playback_tick = host_tick - 100 ms
        I->>I: same
        P->>H: all balls resting
        H-->>S: shot_resolved(shot_id, shooter_id, end_tick, raw_points, trick_ids, foul) [ch3]
        H-->>I: shot_resolved(...) [ch3]
        S->>S: queue; fire "+500!" when playback_tick passes the pot event
        H-->>S: update_cash(absolute) [ch3]
        H-->>I: update_cash(absolute) [ch3]
    end
    Note over H,I: Round end -> push_save_checkpoint(save_version, blob) to every peer
```

## 6. Open questions
- **Deep-link readback on mobile.** The `intent-filter` / URL-scheme side is standard, but Godot 4.7's API for handing the launch URL to GDScript on Android and iOS is unconfirmed. Resolve at M4; worst case is a tiny plugin, or a fallback where the link opens a web page showing the code to paste.
- **Noray relay cost at 4 peers.** Hole-punching succeeds most of the time; carrier-grade NAT on mobile data is the case that forces relay. Measure the relay-fallback rate at M4 before sizing the VPS.
- **Jolt at 240 Hz on a phone.** M0 answers it. If the answer is no, `interp_delay` in ticks and the event `tick_offset u16` range both change — the codec has headroom for 120 Hz.
- **Client authority over its own body.** `push_player_pose` is currently `any_peer`, i.e. trusted. Fine for friends-only; revisit only if public lobbies ever happen (they are explicitly out of scope).

## 7. MVP cut vs later
- **M0 — Mobile perf spike. Gate on everything else.** 16 `Ball` `RigidBody3D` on Jolt at 240 Hz holding 60 fps on a 2022 mid-range Android (Snapdragon 695 / Dimensity 700 class), in a baked bar room with the fog plane and glow on. Fallback ladder if it fails: 120 Hz + CCD → cap balls at 12 → tune sleep thresholds → cut glow. Jolt is 4.7's default engine so there is nothing to install; do trim `physics/jolt_physics_3d/limits` (65,536 body pairs and 20,480 contact constraints are sized for a world, not a pool table) and record the memory delta for 07. No netcode is written until this passes.
- **M1 — Local sim.** Table, balls, cue, scoring. Singleplayer as host-with-zero-peers, `Lobby.tscn` boot, `OfflineMultiplayerPeer`.
- **M2 — `enet_direct`.** Two devices on a LAN by IP, `MultiplayerSpawner` PlayerSlots, lobby roster. Sync still crude (heartbeat only) — this milestone proves the plumbing, not the codec.
- **M3 — Event sync.** Contact events, dead reckoning, playback clock, presentation gating. Verified by `SimDiff`: replay a 40-contact break and assert client-vs-host ball positions stay within 5 mm at every tick.
- **M4 — `enet_noray`.** Self-hosted relay, 6-char lobby code, share link, deep link. Cross-play test is the acceptance criterion: an Android phone on mobile data and a Windows PC in the same lobby.
- **M5 — Session state.** Economy RPCs, Effects, `SaveProfile` broadcast, `save_version` migration, re-host-from-checkpoint drill.
- **M6 — Free roam.** `request_world_interaction` wired to 03's Effects and 02's camera scoring and shop.
- **M7 — GodotSteam (last).** Optional PC peer, invites, overlay. D2 wanted the externally-failable dependency first; P1 made it optional, so a late failure now costs one convenience feature instead of the project — which is exactly why it can be last.
- **Later:** reconnect mid-Round, spectators, rich presence. **Never:** host migration.

### Open-source repo notes
- **Licence split.** Code MIT (`LICENSE`); `assets/` under a separate `LICENSE-ASSETS` reserving art and audio. A fork compiles and plays; it does not ship our bar.
- **No secrets in the tree.** Nothing here needs one: the Noray deployment's `.env` is gitignored with a committed `.env.example`, the Steamworks publisher key never leaves the release machine (app id 480 for dev is public), and `net_config.tres` holds only a plain relay hostname a fork edits to point at its own.
- **Relay is forkable.** `deploy/noray/` ships `docker-compose.yml` and a README with the two ports; anyone can run the whole game on their own infrastructure, which is the point of picking Noray over a platform SDK.
