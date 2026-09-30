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
| `steam` | `SteamMultiplayerPeer` (Steam Sockets) | **Optional, PC only.** Friends-only Steam lobby, overlay invites; the same roster / session-start path as ENet. |

Cross-play is mobile↔PC over `enet_noray`; the `steam` peer is a convenience path between two Steam clients, never a requirement. The Steam extension is loaded conditionally (`OS.has_feature("pc")` and the addon present), so a phone build never references it.

**Noray.** Self-hosted, open source (foxssake/noray, MIT), one small VPS. Control = TCP line protocol (`register-host` → `set-oid`/`set-pid`; `connect <oid>` → `connect <ip:port>`; `connect-relay <oid>` → `connect-relay <port>`), plus a UDP registrar that learns the address a pid appears from. `src/core/noray_client.gd` is our ~100-line client (netfox.noray is not a standalone addon). Flow, host: register → UDP-register from a fresh local port → close that socket → `create_server(port)` on **the same local port** (what `create_client`'s `local_port` argument exists for). Joiner: same registration, `connect <oid>`, then ENet client from its registered port straight at the host (`direct_try_sec`, 3 s); silent → `connect-relay <oid>` and an ENet client at the relay port. The relay maps registered addresses, so plain ENet works through it unchanged. **The host never punches outward** (ENet owns its socket and Godot cannot send raw datagrams from it), so a host behind a port-restricted NAT with no forwarding is reached through the relay; the relay costs the host's uplink only for that session. Config lives in `deploy/noray/.env` (never committed); the client's relay address and ports are plain fields in `net_config.tres`, so a fork points at its own relay by editing one resource. Ports, the docker compose file and the bare-host installer: `deploy/noray/README.md`.

**Invites.** No platform friend graph is assumed, because there isn't one on mobile.
- The relay is configured with `NORAY_OID_LENGTH=6` and the Crockford alphabet (no I/L/O/U), so the host's OID **is** the **6-character lobby code**: ~1.07 billion codes, readable aloud, typeable on a phone keyboard. `LobbyCode.normalize` makes typing forgiving (case-insensitive, `I`/`L`→1, `O`→0).
- The same code is wrapped in a **share link** `http://<relay-host>:8892/j/AB3K7Q` (a stdlib page in `deploy/noray/join_page.py`: code + "Open in game" button + "type the code" text) and the scheme link `absolutebilliard://j/AB3K7Q`. Android's Share button opens the system share sheet (`DeepLink.share`); elsewhere it copies the link.
- Deep-link plumbing: Android `<intent-filter>`s come from the `addons/deeplink` export plugin (the Android preset uses the gradle build; `src/tools/android_export.sh` installs the build template on first run — `android/` is Godot-generated, ~1 GB and gitignored, nothing in it is committed; verified: the exported APK manifest carries both filters, `aapt2 dump xmltree`); iOS URL scheme / Universal Link goes in the plist. **Readback (resolved for Android, 4.7):** `Engine.get_singleton("AndroidRuntime").getActivity().getIntent().getDataString()` — `GodotActivity.onNewIntent` replaces the activity intent, so a warm start reads the same way; the Lobby re-reads it on `NOTIFICATION_APPLICATION_RESUMED`. Desktop launches pass the URL as a command-line argument. iOS readback is unverified.
- **Steam (M7, PC only).** Two GDExtensions, fetched by `src/tools/fetch_godotsteam.sh` into gitignored `addons/` (GodotSteam GDExtension 4.22.1 + expressobits Steam Multiplayer Peer 0.2.5, Linux/Windows 64-bit, `steam_appid.txt` = 480 dev id; the publisher key never enters the repo). `NetManager` loads `src/core/transport_steam.gd` **by path** and only calls it when `OS.has_feature("pc")`, the `Steam` singleton and `SteamMultiplayerPeer` exist and the Steam client answered `steamInit`; every Steam call in that script is dynamic, so no scene or script parses a Steam identifier and the Android preset excludes both addon folders (07 size, P1). Host: friends-only lobby + `create_host(0)`; invite: `activateGameOverlayInviteDialog`; joiner: overlay/friends-list invite fires `join_requested` → `NetManager.join_steam(lobby_id)` → `create_client(lobby owner)`. Lobby shows a "Host on Steam" button only when `steam_available()`. The peer has no channel support (its README), so RPC `transfer_channel` 1–3 collapse onto one — harmless for correctness, only priority is lost. A two-account invite test cannot run on one machine (one Steam client per PC): **waived**, `tests/net/steam_probe.gd` proves init only (`STEAM OK`, or `STEAM SKIP: <reason>`).

### Session start and roster
`NetManager` (autoload) API: `host(transport)` opens a lobby and stays in Lobby, `host_solo()` goes straight to MainLevel with `OfflineMultiplayerPeer`, `join_direct(address, port)`, `join_code(code)`, `leave()`, `get_roster()` (`[{peer_id, name, seat, ready}]`, host seat 0 then join order), `seat_order()`, `start_game()`, `main_level_ready()`. The host owns the roster and pushes it on every join/leave; late joiners are refused once `start_session` ran. `start_session(seed)` loads MainLevel on every peer; each peer then calls `main_level_ready()`, clients answer `peer_ready` to the host, and the host emits `all_peers_ready` once every roster peer reported (solo: immediately). That signal starts the campaign and makes `PlayerSpawner` spawn one `PlayerSlot` per roster peer, so a client never receives a spawn before its own MainLevel exists. Joins fail with `session_failed(reason)` after `timeout_sec`; a vanished host ends the session (`session_ended(&"host_left")`) and everyone returns to Lobby. Player poses: each slot's authority sends `push_player_pose` at 10 Hz (16 B: 3×f32 position, u16 yaw, s16 pitch); other peers smooth the walker toward it.

### 2.4 Roles and sync model
**Host** owns the truth: Jolt sim, `Cash`, `Night`, `Round`, `Effect` timers, `Viewers`. **Clients** send intents and render. **Host migration: skipped** — but the checkpoint broadcast (§2.6) removes the reason people ask for it.

Balls move piecewise: ballistic between contacts, discontinuous at them. So the wire carries **contact events**, not snapshots.

- Host's `PhysicsSim` logs every contact (`contact_monitor` + `max_contacts_reported`, rail shapes carry `rail_id` metadata per D1) and emits `(ball_id, tick, pos, lin_vel, ang_vel)` **after** the impulse resolves.
- Clients **dead-reckon** between events with a shared pure function `BallMotion.advance(state, dt)` — same rolling-resistance model as the host's `_integrate_forces`, no Jolt on the client. Between two events the reconstruction is exact, not approximate; determinism is never needed because every discontinuity is transmitted.
- **Interpolate only, never extrapolate.** The client renders at `playback_tick = host_tick − interp_delay`, so every event it needs has already arrived. Extrapolating near a cushion is how you render a ball through a rail.
- A **2 Hz full-state heartbeat** corrects drift and re-seats a client that missed a packet or joined mid-shot.
- **Presentation is gated on the playback clock, not on packet arrival.** `shot_resolved` reaches the client ~100 ms before the client has finished watching the shot; it is queued and the `+500!` popup, the pot sound and the cash tick fire when `playback_tick` passes the potting event. Without this the score appears before the ball drops.

Events are **hand-packed** into a `PackedByteArray`, not pushed through `MultiplayerSynchronizer` — the synchroniser samples state on a timer, which is the snapshot model we just rejected. `MultiplayerSpawner` *is* used, but only for `PlayerSlot`s (§4).

**Codec** (`BallEventCodec`, implemented). Frame = `shot_id u16 | base_tick u32 | count u8` then `count` × 21-byte events: `id_flags u8 | tick_offset u16 | pos 3×s16 | lin 3×s16 | ang 3×s16`. `id_flags` = ball id (6 bits, < 64) | flag << 6 (`NONE`, `POCKETED`, `RETIRED`, `RESTORED`). Fixed point, not f16 (f16 cannot hold 0.1 mm over a 5 m table): pos 0.1 mm about the Table origin (±3.27 m, error ≤ 0.05 mm), lin 0.5 mm/s (±16.3 m/s), ang 0.02 rad/s (±655 rad/s). `tick_offset` counts `LIVE_TICK` ticks from `base_tick` (= `Engine.get_physics_frames()` at the strike); `0xFFFF` = "apply now" for lifecycle events between shots. A frame holds ≤ 255 events; a 40-contact break is ~190 events ≈ 4 KB, well inside the 07 §3 budget (≤ 200 events/shot).

**What is sent.** The host keeps, per ball, the state a client will have reconstructed (the last *sent, quantized* state advanced by `BallMotion.advance` each tick). It emits an event when a contact flags the ball (both balls), or when that prediction drifts > `DIVERGE_M` (2 mm [tune]) from Jolt, or when Jolt says rest but the prediction is still moving. So the 5 mm client-vs-host gate holds **by construction**, not because the model is exact; determinism is never needed. Events are coalesced per tick and flushed at 30 Hz (reliable, ch1). A 2 Hz **heartbeat** (unreliable ch2, full state) runs only while a Shot is live and is *corrective*: a client adopts a heartbeat state only when it is > 6 mm off (lost packet, late join), otherwise the host's prediction bookkeeping would no longer match what clients render. The net is silent at rest (R3).

**Client** (`BallReplica` + `PhysicsSim`). Balls are kinematic. Per ball, a tick-sorted event list; a sample at tick T dead-reckons the newest event ≤ T with `BallMotion.advance` (interpolation only: the client renders at `playback_tick = shot_start + elapsed − 100 ms`, so events have already arrived). `shot_started` re-bases the clock and freezes every ball at its on-screen state. Visual spin integrates `ang_vel` per frame. Lifecycle flags (`POCKETED`, `RETIRED`, `RESTORED`) apply at their playback tick; `RoundDirector` derives the pocket from the nearest `PocketSpec` and re-emits `ball_potted`, and `shot_ended` fires when `playback_tick` passes the `end_tick` carried by `shot_resolved`. Host and client predict from the **same** `BallMotion.Params`: `cloth_friction_mult` and `table_tilt_deg` + direction ride `shot_started` (4th arg, 4 floats) and, when they change mid-Shot, a ch1 `_motion_stats_rpc(tick, stats)` applied at its playback tick (the client applies it to the whole span since its last event, so a mid-shot change costs a few extra divergence events). Cushion restitution and ball mass are contact-side, so they stay host-only. Lifecycle events sent right after a Shot (kitchen respawn) are stamped `end_offset + 1`, which orders them after any pot/retire flags the client still has queued. Modded numbers (`simdiff_probe`, cloth 0.7 + tilt 1°): max err 2.55 mm, 298 events on a 108-contact shot (plain: 190 on 81) — the 07 §3 200-event budget is a plain-break figure; drinks lengthen shots. **Pocket oscillation clock.** `Table.pocket_offset(seed, id, t, amp)` is drawn and captured from one clock, `PhysicsSim.pocket_time()`: the host's monotonic clock (the one its drop-chute Areas capture against); a client runs that clock as of the last sync (`shot_started`, `push_rack`, `full_state` carry it) minus the 100 ms playback delay, so the liner is drawn where the host's Jolt would catch a ball it sees now. Zero packets in between; a shot start re-anchors it (drift is the two monotonic clocks' rate difference over one shot). **Backgrounding (§6).** `NetManager` turns `NOTIFICATION_APPLICATION_PAUSED/RESUMED` (and focus out/in on Android only) into `app_paused`/`app_resumed`. A paused client is *blind*: `PhysicsSim` drops event and heartbeat frames and `request_shot` sends nothing (PLAYER gates pose sends on `NetManager.backgrounded`). On resume it sends `request_full_state`; the snapshot replaces every ball's replica history (`apply_snapshot`, playback clock re-based on the snapshot tick) and only then does it leave the blind state. Solo (`OfflineMultiplayerPeer`) never goes blind and sends nothing. `resume_bg_pair_probe`: a client paused through a whole host shot is 2.0 m stale, back within 5 mm ≤ 1 s after resume with Turn/shooter/Cash equal. `NetGraph` (F8, `src/debug`) shows events/s, bytes/s, playback lead and the last SimDiff error.

**Model** (`BallMotion.advance(state, dt, params)`, pure). Coulomb slide → roll (slip < 5 mm/s), rolling-resistance decel, Jolt's default linear/angular damping folded in as `(lin + 0.4·ang) / 1.4`, spin about the normal decaying exponentially, ballistic flight above `floor_y` (a pocketed ball's floor is −100 m: it falls through the cloth plane like Jolt's). Cushions, balls, jaws and landings are not modelled — they are events. `tests/sync/simdiff_probe.gd` (`SimDiff`): 40+ contact break, 50 ms simulated link, playback 100 ms behind → max error ≈ 2 mm, ≈ 190 events.

### 2.5 Channels
`transfer_channel 0` is internally three ENet channels (one per transfer mode), so channel 0 traffic never blocks the others by default. We still split explicitly:

| Ch | Carries | Why |
|---|---|---|
| 0 | Godot internals, `MultiplayerSpawner` replication | Leave it alone. |
| 1 | Shot intents, contact events (**reliable**) | Sparse and each one unrecoverable if lost — a dropped contact event corrupts dead reckoning forever. Reliability is cheap at ~40 packets per shot. |
| 2 | Shot-live heartbeat (2 Hz, corrective), viewer count, player poses (**unreliable_ordered**) | Redundant and frequent; a late one is worse than a lost one. |
| 3 | Session, economy, effects, saves (**reliable**) | Must not be blocked behind a sim burst. |

Allocate `channel_count = 8` in `create_server` / `create_client` for headroom.

### 2.6 Save data
`SaveProfile` is JSON, under 1 KB, written by `SaveManager` (a static class — **not** an autoload).

```json
{
  "save_version": 2,
  "crew_cash": 1500,
  "current_night": 3,
  "round_index": 2,
  "quota_target": 1350,
  "viewers": 640,
  "hype": 0.4,
  "unlocked": { "ball_types": ["tier2_rack"], "cameras": ["lens_t2"], "cue": ["heavy_shaft"] },
  "owned_items": { "tier2_rack": 1, "lens_t2": 1, "heavy_shaft": 1, "fresh_cloth": 1 },
  "persistent_unlocks": ["tier2_rack", "lens_t2"],
  "seed": 884213
}
```

`round_index` = Rounds finished this Night (`0` = Night start); after a passed Night the resume point is the next Night's start. `owned_items` (Shop id → count) is the truth; `unlocked` is a per-category read-only view of it. `viewers = -1` means "start from the Night's `base_viewers`". Built by `GameLoop.build_profile()`, resumed by `GameLoop.resume_from(profile)`.

`save_version` gates migration: on load, an older version runs through `SaveManager.migrate(profile)` (v1 = the first sketch, ids per category and no `owned_items`/`viewers`/`hype`); a newer version returns `null` with `SaveManager.last_error = &"newer_version"` rather than silently dropping fields.

**Rules (implemented).** One file per session key, overwritten at every Round end; a finished run (game over or campaign won) deletes it on the host and, through an empty-blob `push_save_checkpoint`, on every client; only the newest `SaveManager.KEEP_CHECKPOINTS` (10) files are kept. Checkpoints are JSON only, never `bytes_to_var`. Resuming reads the picked file and leaves it in place; the resumed session writes under its own new key (a fresh Noray code / LAN seed) at its first Round end, so the old file just ages out. **Any peer can re-host** from its own copy: the crew size need not match `crew_size` (informational) — nobody is seat-locked, seats are reassigned by join order, and the checkpoint carries the shared purse, not per-player state.

Files: `user://checkpoints/<key>.json` where `key` = Noray lobby code, else `solo`, else `lan-<session seed>` (`SaveManager.checkpoint_key`); `user://profile.json` = `persistent_unlocks` only, written on every persistent purchase and read by a new campaign (02 §3.7). The Lobby's "Resume" (a sub-screen, hidden when there are no files) lists `SaveManager.list_checkpoints()` newest first (Night · Round done · Cash · crew · date); picking a row sets `SaveManager.pending_resume = SaveManager.load_checkpoint(path)` then hosts — `solo` files via `host_solo()`, others by relay, or LAN when "Advanced" is open; `Leave` / a failed host drops the pick; `main_level.gd` hands it to `GameLoop.resume_from`.

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
├── debug/           dev-only overlay (DebugRoot.tscn, HUD/freecam/gizmos/spec panel/shot
│                    console/timescale/rack presets, src/debug/README.md); NetGraph.tscn ·
│                    SimDiff.gd (M3 reconstruction check) still to come
└── tools/           bake_lightmaps.gd · pack_release.sh
deploy/noray/        docker-compose.yml · .env.example
tests/               physics fixtures (D1) · codec round-trip · migration
```

Boot scene is **`Lobby.tscn`** (M1, done). Singleplayer is not a separate mode: it is **a host with zero peers** — `Lobby.tscn`'s "Solo" button calls the same `host()` path, `NetManager` installs an `OfflineMultiplayerPeer`, and every RPC below still fires locally through `call_local`. No branch anywhere else in the codebase says `if singleplayer`.

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
| `request_shot(intent)` — wire: `_request_shot_rpc(blob 6×f32 + called-pocket index u8)`; the public `PhysicsSim.request_shot` is the entry (solo = local call) | PhysicsSim | C→H | `any_peer` | `call_remote` | `reliable` | 1 |
| `shot_rejected(reason)` — `_shot_rejected_rpc`, also a local signal | PhysicsSim | H→1 | `authority` | `call_remote` | `reliable` | 1 |
| `shot_started(shot_id, shooter_id, base_tick)` — `_shot_started_rpc(…, stats: 4×f32, host_pocket_t: f64)` → signal `shot_started_net`; the last arg syncs the pocket clock | PhysicsSim | H→A | `authority` | `call_local` | `reliable` | 1 |
| `push_contact_events(shot_id, base_tick, blob)` — `_push_events_rpc` | PhysicsSim | H→A | `authority` | `call_remote` | `reliable` | 1 |
| `push_heartbeat(tick, blob)` — `_push_heartbeat_rpc` | PhysicsSim | H→A | `authority` | `call_remote` | `unreliable_ordered` | 2 |
| `motion_stats(tick, stats)` — `_motion_stats_rpc`, mid-Shot friction/tilt change | PhysicsSim | H→A | `authority` | `call_remote` | `reliable` | 1 |
| `shot_resolved(shot_id, shooter_id, end_tick, raw_points, trick_ids, foul)` — `_shot_resolved_rpc`, **`call_remote`**: the host already emitted `shot_ended` itself | RoundDirector | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `push_rack(round_id, seed, blob, host_pocket_t)` — `_push_rack_rpc`; blob = `net_id u8, type u8, x f32, z f32` per ball | RoundDirector | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `spawn_ball(net_id, type, x, z, tick)` — `_spawn_rpc`: a split's red, applied at `tick` (after the Shot's playback) | RoundDirector | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `reroll_ball(net_id, type, tick)` — `_reroll_rpc`: shuffle, in place | RoundDirector | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `shot_clock(seconds)` — `_shot_clock_rpc`: the shooter's clock armed | RoundDirector | H→A | `authority` | `call_local` | `reliable` | 3 |
| `request_full_state()` — `_request_full_state_rpc`: a client back from the background asks for everything | RoundDirector | C→H | `any_peer` | `call_remote` | `reliable` | 3 |
| `full_state(round_id, seed, shot_index, shooter_id, active, live, clock_left, rack_blob, ball_frame, host_pocket_t)` — `_full_state_rpc`: `rack_blob` is the `push_rack` blob, `ball_frame` a `BallEventCodec` frame of every ball (lifecycle in the event flags) at the host's current tick. Then the host calls `resync_peer(peer)` on GameLoop (`round_state`), EconomyManager (`update_cash` + `update_owned`), EffectManager (`_resync_effects_rpc`: adds missing Effects, syncs remaining time) | RoundDirector | H→C | `authority` | `call_remote` | `reliable` | 3 |
| `host_away(away)` — `_host_away_rpc`: the host's app paused / resumed; clients show "host away" (`NetManager.host_away`). The host's resume also sends `full_state` to every client | NetManager | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `set_shooter(peer_id)` — `_set_shooter_rpc` | RoundDirector | H→A | `authority` | `call_local` | `reliable` | 3 |
| `round_state(night_index, round_index, phase, time_left, shots_left, round_points, round_seed, end_reason)` | GameLoop | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `push_shot_settled(shot_id, cash, trick_id, foul)` | GameLoop | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `update_cash(absolute_balance, delta, reason)` | EconomyManager | H→A | `authority` | `call_local` | `reliable` | 3 |
| `quota_result(paid, demand, is_game_over)` | EconomyManager | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `request_purchase(item_id, target_peer_id)` | EconomyManager | C→H | `any_peer` | `call_local` | `reliable` | 3 |
| `reject_purchase(item_id, reason)` | EconomyManager | H→1 | `authority` | `call_local` | `reliable` | 3 |
| `update_owned(ids, counts, item_id, buyer_peer_id)` | EconomyManager | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `update_viewers(count, hype)` | StreamManager | H→A | `authority` | `call_remote` | `unreliable_ordered` | 2 |
| `push_rig_poses(poses, holders)` | Cameras | H→A | `authority` | `call_remote` | `unreliable_ordered` | 2 |
| `apply_effect(effect_id, owner_peer_id, target_id, duration_ms)` | EffectManager | H→A | `authority` | `call_local` | `reliable` | 3 |
| `resync_effects(ids, owners, targets, durations, remaining)` — `_resync_effects_rpc`: sent with `full_state` to one client; adds Effects it lacks and syncs remaining time | EffectManager | H→1 | `authority` | `call_remote` | `reliable` | 3 |
| `apply_event(event_id, round_index, pocket_id)` | EventScheduler | H→A | `authority` | `call_local` | `reliable` | 3 |
| `event_offer(round_index, tier, event_ids)` | EventScheduler | H→A | `authority` | `call_local` | `reliable` | 3 |
| `submit_event_vote(event_id)` | EventScheduler | C→H | `any_peer` | `call_local` | `reliable` | 3 |
| `request_world_interaction(kind, target_id, payload)` | MainLevel/WorldInteractions | C→H | `any_peer` | `call_remote` | `reliable` | 3 |
| `world_interaction_applied(peer_id, kind, target_id, payload)` | MainLevel/WorldInteractions | H→A | `authority` | `call_local` | `reliable` | 3 |
| `world_interaction_rejected(kind, reason)` | MainLevel/WorldInteractions | H→1 | `authority` | `call_remote` | `reliable` | 3 |
| `push_save_checkpoint(save_version, blob)` | NetManager | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `push_roster(roster)` — `_push_roster`: the seat list (host-written, clients mirror) | NetManager | H→A | `authority` | `call_remote` | `reliable` | 3 |
| `peer_ready()` | NetManager | C→H | `any_peer` | `call_remote` | `reliable` | 3 |
| `start_session(seed)` | NetManager | H→A | `authority` | `call_local` | `reliable` | 3 |
| `push_player_pose(blob)` | PlayerSlot | any→A | `any_peer` | `call_remote` | `unreliable_ordered` | 2 |

`update_cash` carries the **absolute** balance, never a delta — a lost or reordered delta desyncs the crew purse permanently; `delta`/`reason` ride along only so the HUD can flash a tip. The host handler is a no-op (`add_cash` already applied it). `update_viewers` is display-only (the host computes income from its own value), so losing one costs a frame of a number; hype decay reaches clients at ≤ 4 Hz, and `GameLoop` re-sends it with a 1 Hz `round_state` heartbeat during a live Round (phase changes are sent at once; nothing is sent at rest). Clients re-emit `night_started` / `round_started` / `round_ended` / `intermission_started` / `night_ended` from `round_state` in the host's order, so the HUD is identical on every peer. `push_rig_poses` is 4 floats per rig (x, y, z, yaw) plus a `PackedInt32Array` of holder peer ids (0 = free) at 4 Hz, only while a rig moved or changed hands, plus a few repeats at rest; the Player derives `CARRY` from the holders (08 §5). `push_save_checkpoint` lands in `SaveManager.receive_checkpoint`.

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
- **Backgrounded phones (ruled by alpha, REQ#rules-2).** ENet's default drops a peer after 5 s unacked (never waits past 30 s). `NetConfig.peer_timeout_limit/min_ms/max_ms` = `32 / 45000 / 60000` is applied to every ENet peer on both sides (`NetManager._relax_timeout`), so a 30 s background survives with margin; a peer that is really gone is noticed after ≤ 60 s. [tune] on a device: Android may freeze the socket harder than a desktop fake pause shows.
- **Deep-link readback on iOS.** Android is resolved (§2.3: `AndroidRuntime` → `getIntent().getDataString()`, warm and cold start). iOS needs the URL-scheme plist entry plus a readback that is unverified; worst case is a tiny plugin, or a link that opens the web page showing the code to paste. Android *manifest* injection needs the custom gradle build template — untested on a device until the alpha toolchain slice exports.
- **Host-side hole punching.** Not implemented: Godot's ENet cannot send raw datagrams from its own socket, so a host behind a port-restricted NAT with no forwarding is reached via the relay. If measurement (next bullet) shows too many relay sessions, the fix is an ENet mesh peer that connects outward.
- **Noray relay cost at 4 peers.** Hole-punching succeeds most of the time; carrier-grade NAT on mobile data is the case that forces relay. Measure the relay-fallback rate at M4 before sizing the VPS.
- **Jolt at 240 Hz on a phone.** M0 answers it. If the answer is no, `interp_delay` in ticks and the event `tick_offset u16` range both change — the codec has headroom for 120 Hz.
- **Client authority over its own body.** `push_player_pose` is currently `any_peer`, i.e. trusted. Fine for friends-only; revisit only if public lobbies ever happen (they are explicitly out of scope).

## 7. MVP cut vs later
- **M0 — Mobile perf spike. Gate on everything else.** 16 `Ball` `RigidBody3D` on Jolt at 240 Hz holding 60 fps on a 2022 mid-range Android (Snapdragon 695 / Dimensity 700 class), in a baked bar room with the fog plane and glow on. Fallback ladder if it fails: 120 Hz + CCD → cap balls at 12 → tune sleep thresholds → cut glow. Jolt is 4.7's default engine so there is nothing to install; do trim `physics/jolt_physics_3d/limits` (65,536 body pairs and 20,480 contact constraints are sized for a world, not a pool table) and record the memory delta for 07. No netcode is written until this passes.
- **M1 — Local sim.** Table, balls, cue, scoring. Singleplayer as host-with-zero-peers, `Lobby.tscn` boot, `OfflineMultiplayerPeer`.
- **M2 — `enet_direct`.** Two devices on a LAN by IP, `MultiplayerSpawner` PlayerSlots, lobby roster. Sync still crude (heartbeat only) — this milestone proves the plumbing, not the codec. *Built 2026-09-30: `tests/net/pair.sh tests/net/pair_probe.gd`.*
- **M3 — Event sync.** Contact events, dead reckoning, playback clock, presentation gating. Verified by `SimDiff`: replay a 40-contact break and assert client-vs-host ball positions stay within 5 mm at every tick.
- **M4 — `enet_noray`.** Self-hosted relay, 6-char lobby code, share link, deep link. Cross-play test is the acceptance criterion: an Android phone on mobile data and a Windows PC in the same lobby. *Built 2026-09-30 minus the phone test: `pair.sh … --noray` joins by code through the relay; Android build untried.*
- **M5 — Session state.** Economy RPCs, Effects, `SaveProfile` broadcast, `save_version` migration, re-host-from-checkpoint drill.
- **M6 — Free roam.** `request_world_interaction` wired to 03's Effects and 02's camera scoring and shop.
- **M7 — GodotSteam (last).** Optional PC peer, invites, overlay. D2 wanted the externally-failable dependency first; P1 made it optional, so a late failure now costs one convenience feature instead of the project — which is exactly why it can be last. **Built:** transport, Lobby button, fetch script, init probe (see §2.3); invite round-trip waived (single Steam client).
- **Later:** reconnect mid-Round, spectators, rich presence. **Never:** host migration.

### Open-source repo notes
- **Licence split.** Code MIT (`LICENSE`); `assets/` under a separate `LICENSE-ASSETS` reserving art and audio. A fork compiles and plays; it does not ship our bar.
- **No secrets in the tree.** Nothing here needs one: the Noray deployment's `.env` is gitignored with a committed `.env.example`, the Steamworks publisher key never leaves the release machine (app id 480 for dev is public), and `net_config.tres` holds only a plain relay hostname a fork edits to point at its own.
- **Relay is forkable.** `deploy/noray/` ships `docker-compose.yml` and a README with the two ports; anyone can run the whole game on their own infrastructure, which is the point of picking Noray over a platform SDK.
