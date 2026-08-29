# 07 — Optimization (mobile-first)

Mandate: P4 of `06-final-decisions.md`. P1 makes performance a design constraint, not a later phase.

**Target device class** (the budget is written against the *worst* of these, not the average):

| tier | device | GPU | what it gates |
|---|---|---|---|
| floor | Snapdragon 695 / Dimensity 900 Android, 2022 | Adreno 619 / Mali-G68 MC4 | every budget below |
| floor | iPhone 11 (A13) | Apple GPU 4-core | Metal path, thermal ceiling |
| ref | dev PC | anything | never used to sign off a budget |

**Scene**: one bar room, one table, ≤ 12 object balls + cue (`13 rigid bodies [tune]`), up to 4 networked players free-roaming (P2), 2–4 stream `Camera`s, drink/event `visual_hook` effects.

**Frame budget @ 60 fps = 16.6 ms.** CPU (main thread, GDScript is single-threaded):

| stage | budget | note |
|---|---|---|
| Jolt step ×4 (240 Hz tick) | `4.0 ms [tune]` | 1.0 ms per step for 13 bodies |
| `_integrate_forces` + `_physics_process` | `1.5 ms [tune]` | 52 calls/frame at 240 Hz |
| `_process` (HUD, cameras, effects) | `1.0 ms [tune]` | |
| rendering CPU (cull + submit) | `3.0 ms [tune]` | |
| netcode pack/send/recv | `0.6 ms [tune]` | |
| audio + engine misc | `1.0 ms [tune]` | |
| **CPU total** | **`11.1 ms`** | 5.5 ms slack for OS + thermal drift |
| **GPU total** | **`13.0 ms [tune]`** | at 1080p × `0.85` render scale |

Everything below is per aspect: budget → measurement → techniques in priority order → what not to do → one acceptance test.

---

## 1. Physics (Jolt)

| metric | budget |
|---|---|
| Jolt step, 13 awake bodies | `≤ 1.0 ms [tune]` |
| Jolt step, table at rest | `≤ 0.05 ms [tune]` (all bodies asleep) |
| bodies with CCD active at once | `≤ 2 [tune]` |
| contacts reported per step | `≤ 40 [tune]` |
| time from strike to all-asleep | `≤ 9 s [tune]` |
| ball cap | `12 object + 1 cue [tune]`, pool of 17 |

**Measure.** Debugger → Monitors: `Physics 3D/Active Objects`, `Physics 3D/Collision Pairs`, `Physics 3D/Islands`; Profiler `Physics Frame` column. On device: export with *Deploy with Remote Debug* (Godot sets up `adb reverse tcp:6007`) so the Profiler shows phone numbers, not PC numbers. Custom monitor `Game/AwakeBalls` for the sleep behaviour.

**Techniques, in order.**
1. **Collision layers first — it is free.** 1 `balls`, 2 `table_rails`, 3 `pockets` (Area3D), 4 `world` (players, stools, jukebox). Ball mask = `1|2|3` only. Free-roaming players and bar props are *never* tested against balls; table-bumping (P2) is a scripted `Effect`, not a collision. This removes 13 × 4 player-capsule pairs × 240 Hz from the broad phase.
2. **240 Hz tick, CCD gated on speed.** At 240 Hz a 10 m/s ball travels `41.7 mm` per step, under the `57.15 mm` ball-ball contact distance — discrete detection holds for ball-ball. It does *not* hold for the pocket jaw cylinders. So: `Ball.continuous_cd` toggled on when `linear_velocity.length() > 3.0 m/s [tune]`, off below. Cue ball keeps it on for the whole shot. Fallback ladder if the 695 misses budget: `240 Hz + gated CCD` → `120 Hz + CCD on all` (120 Hz travels 83 mm/step, CCD is then mandatory) → `120 Hz + max_physics_steps_per_frame 8`.
3. **Sleep aggressively, and use sleep as the shot boundary.** Jolt has its *own* sleep settings: `physics/jolt_physics_3d/simulation/sleep_velocity_threshold = 0.05 [tune]`, `sleep_time_threshold = 0.3 [tune]`. Connect `RigidBody3D.sleeping_state_changed` and count awake balls; zero awake ⇒ `shot_resolved`. This kills the per-frame velocity poll *and* drops the sim to ~0 cost between shots.
4. **Contact monitoring only during a live `Shot`.** `contact_monitor = true` at strike, `false` at rest. `max_contacts_reported = 6 [tune]` on object balls, `8` on the cue. Rails carry `rail_id` metadata (D1) so the ordered contact log is built from the signal, not from a per-step scan.
5. **Physics interpolation on** (`physics/common/physics_interpolation = true`). Cheap insurance for the 30 fps and 120 Hz modes. Call `reset_physics_interpolation()` on Poisson-disk drop and on kitchen respawn or you get streak artifacts.
6. Raise `physics/common/max_physics_steps_per_frame` to `8` so a 30 fps dip does not slow the sim; below that Godot silently stretches time.

**Do not.** Do not tune `physics/3d/solver/*` or `PhysicsServer3D` sleep-velocity params — **Jolt ignores them**, they are GodotPhysics3D-only. Do not set `continuous_cd` on all 13 balls permanently. Do not raise the tick above 240 Hz "for accuracy" — a 30 fps frame then needs 8 steps and physics doubles per frame. Do not poll velocities at 240 Hz to detect rest.

**Acceptance:** `perf_break.tscn` at max power, 100 runs, zero balls outside the table AABB and mean Jolt step `≤ 1.0 ms` on the Snapdragon 695.

---

## 2. Rendering (Mobile renderer)

Mobile has **no** SSAO, SSR, SSIL, SDFGI, volumetric fog, TAA, FSR2 or auto-exposure. It **does** have MSAA 2D/3D, FXAA/SMAA, glow, depth+height fog, CompositorEffects, PCSS for omni/spot, LightmapGI, 8 omni/spot per mesh and 256 per view. The dim-bar mood is built from baked light + emissive + a fog plane (P1), not from post-processing.

| metric | budget |
|---|---|
| draw calls / frame | `≤ 120 [tune]` |
| unique materials in the bar | `≤ 12 [tune]` |
| visible triangles | `≤ 60k [tune]` |
| realtime lights | `3 [tune]`, of which **1** casts shadows |
| fullscreen post passes | `1 [tune]` |
| GPU frame | `≤ 13.0 ms [tune]` @ scale 0.85 |

**Measure.** Debugger → **Visual Profiler** for per-pass GPU time; Monitors `Render/Total Draw Calls in Frame`, `Render/Total Primitives in Frame`, `Render/Video Mem Used`. Android: `adb shell dumpsys gfxinfo <pkg> framestats` for jank distribution. iOS uses Godot's native Metal driver (4.4+), so Xcode → Instruments *Game Performance* / Metal System Trace and the GPU frame capture work directly on the shipped build.

**Techniques, in order.**
1. **Bake everything static.** `LightmapGI` for the room, emissive materials for the neon/table lamp/TV screens, one fog plane. Props marked `Static` bake mode. This is the whole "mood" budget.
2. **One shadow-casting light: a SpotLight3D over the table.** A spot shadow is 1 map; an omni is 6 cube faces for the same visual result. Atlas `2048`, spot quadrant `1024 [tune]`. Only balls, cue and players cast into it; every prop is `shadow_casting = Off` and baked instead.
3. **One ball material.** A single 1024² ball atlas + `set_instance_shader_parameter()` for per-ball colour keeps all 13 balls on one pipeline. 13 draw calls is not a problem — go `MultiMeshInstance3D` only if the draw-call monitor actually breaches 120.
4. **Merge the bar by material** into `≤ 8 [tune]` static meshes; `visibility_range_*` (LOD/fade) on stools, bottles and the far wall.
5. **MSAA 2× 3D**, no FXAA. Tile-based GPUs resolve MSAA in tile memory (near-free at 2×); FXAA smears the felt texture and fails exactly on the thin cue stick. `4×` on iPhone 11 only.
6. **`visual_hook` effects are one ubershader on one fullscreen `ColorRect`** — vignette, `lights_out` darkening, drunk-wobble UV offset, `crowd_roar` flash all as branches on float uniforms, mixed in a single pass. Never stack one pass per active Effect.
7. **Render scale `0.85 [tune]`** (`rendering/scaling_3d/mode = bilinear`) as the first thermal lever; FSR2 is not available on Mobile.

**Do not.** Do not enable occlusion culling — one room where nearly everything is visible costs more CPU raster than it saves. Do not read `hint_screen_texture` with a mipmap filter (forces a screen copy + mip chain every frame). Do not add a second shadow-casting light "for the bar". Do not run uncapped above the panel rate.

**Modes:** `60 fps` (default) / `30 fps` battery / `120 fps` PC only. The 30 fps mode **must** also drop the physics tick to 120 Hz — otherwise it is 8 Jolt steps per frame and saves nothing.

**Acceptance:** `perf_bar.tscn` orbit, 60 s on the 695 — `≥ 95%` of frames under 16.6 ms, draw calls `≤ 120`.

---

## 3. Netcode

Event-based sync per D2, ENet + Noray primary per P1. Mobile radios punish *packet cadence*, not bytes.

| metric | budget |
|---|---|
| contact event, packed | `16 B [tune]` |
| events per `Shot` | `≤ 200 [tune]` (a break is ~40 in the first 0.5 s) |
| host upstream, shot in flight | `≤ 16 KB/s [tune]` total, all peers |
| host upstream, table at rest | `≈ 0` (ENet's own ping only) |
| packet cadence during a shot | `30 Hz [tune]`, fixed |
| client interpolation delay | `100 ms [tune]` |
| full-state resync packet | `≤ 512 B [tune]` |

**Packing.** `ball_id: u8` + `tick_delta: u16` + position as 3× `u16` quantized over the table AABB (0.04 mm resolution) + velocity as 3× `f16` = 15–16 B. Never send `Vector3` as three `f32` through a `Dictionary`.

**Channels.**

| ch | mode | carries |
|---|---|---|
| 0 | reliable ordered (4.7 default) | lobby, `shot_resolved`, `update_cash`, `apply_event`, `SaveProfile` broadcast |
| 1 | `unreliable_ordered` | batched ball contact events, 2 Hz heartbeat |
| 2 | `unreliable` | free-roam player transforms, `4 players × 10 Hz [tune]`, 12 B each |

**Measure.** Custom monitors `Game/NetBytesPerSec` and `Game/EventsPerShot`; `MultiplayerPeer` stats. On device: `adb shell dumpsys netstats` and Perfetto's radio track to confirm the radio drops to idle between shots. Test on a real cellular link at least once — Wi-Fi hides tail-energy entirely.

**Techniques, in order.**
1. **Coalesce per physics frame, flush at 30 Hz.** 240 Hz ticks must never become 240 packets/s. One packet holds every event since the last flush.
2. **Silence at rest.** Between shots send nothing; ENet's own ping (500 ms) keeps the connection. The heartbeat is `2 Hz` *only while a shot is live*.
3. **Interpolate, never extrapolate near a cushion** (D2). Gate `+500!` popups on the client playback clock.
4. **Reconnect from the last checkpoint.** `SaveProfile` (<1 KB) broadcast at each Round end; on rejoin the host sends one reliable full-state packet (13 transforms + economy + active Effects). Hold the slot `30 s [tune]`.
5. **Backgrounding is a disconnect.** On `NOTIFICATION_APPLICATION_PAUSED` stop sending; on resume always request full state — never resume dead-reckoning across a suspend.

**Do not.** Do not send snapshots at 20 Hz (04's original plan — that is 20× the bytes and reconstructs cushion contacts as straight lines). Do not send per-event packets. Do not add an app-level idle heartbeat on top of ENet's ping. Do not stream free-roam player transforms reliably.

**Acceptance:** a full break on a 4-player lobby stays under `16 KB/s` host upstream, and a client killed mid-shot rejoins to a correct table within `3 s`.

---

## 4. Memory (Godot refcounts — there is no GC)

No tracing GC means no GC pauses, but allocation spikes and `free()` cascades still land on the main thread.

| metric | budget |
|---|---|
| RSS, Android | `≤ 500 MB [tune]` |
| RSS, iPhone 11 | `≤ 400 MB [tune]` |
| `MEMORY_STATIC` | `≤ 260 MB [tune]` |
| texture VRAM | `≤ 180 MB [tune]` |
| audio RAM | `≤ 25 MB [tune]` |
| node count | `≤ 1500 [tune]` |
| **orphan nodes at Round end** | **`0`** |

**Measure.** Monitors `Memory/Static`, `Render/Video Mem Used`, `Object/Nodes`, `Object/Orphan Nodes`. `adb shell dumpsys meminfo <pkg>` for the real RSS the OOM killer sees; Xcode → Instruments *Allocations* + *Leaks*.

**Techniques, in order.**
1. **`RefCounted` or plain packed arrays for data, `Node` only for things in the tree.** `Shot`, `RoundState`, `StatMod`, `ContactEvent` are never Nodes. The per-shot contact log is a pre-sized `PackedInt32Array` + `PackedVector3Array` ring, allocated once — not 200 `ContactEvent.new()` calls per shot.
2. **Pool what repeats.** Balls: `17 [tune]` instanced at Round start, hidden + `freeze = true` when unused, never `queue_free()` between Rounds. Effects: `8 [tune]` one-shot `GPUParticles3D`, `4 [tune]` impact decals, `4 [tune]` score popups, `12 [tune]` `AudioStreamPlayer3D` voices round-robin.
3. **Texture memory via import, not code** — see §8. Mipmaps always on for 3D; they *reduce* bandwidth as well as aliasing.
4. **Audio: WAV/QOA for impacts, Ogg Vorbis for ambience.** Short SFX decoded on load (no playback spike); one streamed music/ambience track, not six.
5. **`preload()` only what is instanced more than once**, and only in the scene that owns it — not in an autoload.

**Do not.** Do not `queue_free()` and re-instance balls each Round. Do not build `Array`/`Dictionary`/`String` per frame. Do not put `MainLevel` or the prop library behind an autoload `preload`. Do not hold `Image` data after upload.

**Acceptance:** five Rounds back to back — `Object/Orphan Nodes` is 0 and `Memory/Static` at Round 5 is within `5%` of Round 1.

---

## 5. GDScript hot paths

The single hottest function in this game is `Ball._integrate_forces`: 13 bodies × 240 Hz = **3120 calls/s**.

| metric | budget |
|---|---|
| `_integrate_forces`, per call | `≤ 6 µs [tune]` |
| all `_physics_process` scripts / frame | `≤ 1.5 ms [tune]` |
| all `_process` scripts / frame | `≤ 1.0 ms [tune]` |
| allocations per frame in hot paths | `0` |

**Measure.** Debugger → Profiler, sort by *Self* time, on the device. The Profiler lists per-function self/total ms — anything over `0.3 ms` self in a 13-ball scene is a bug, not a budget.

**Techniques, in order.**
1. **Static types everywhere**, including `:=` inference and `Array[Ball]` / `PackedVector3Array`. Typed operands compile to specialised opcodes; this is the cheapest 2–4× on arithmetic loops available.
2. **Try engine-side damping before writing `_integrate_forces` at all.** `linear_damp` / `angular_damp` with `damp_mode = REPLACE` is free (C++, inside Jolt's step). If the roll feel holds, the hottest GDScript function in the game does not exist. If it does not hold, D1's custom rolling-resistance torque stands — but it must stay ~20 lines and do nothing else.
3. **Sleeping bodies skip `_integrate_forces` entirely.** §1's sleep thresholds are a GDScript optimization as much as a physics one.
4. **Cache node refs in `@onready`.** No `$Path`, `get_node()`, `is_instance_valid()` chains or `find_child()` in a 240 Hz function.
5. **Signals for state changes, loops for dense per-frame data.** `sleeping_state_changed` (13 emissions per shot) beats polling 13 velocities 3120×/s. But a signal costs ~1 µs to emit — do not emit one per contact per step; the contact log appends, the detector runs once at rest. Trick detection and scoring run **once per `Shot`**, never per tick.
6. **No per-frame string work.** HUD text updates on `cash_changed` / `viewers_changed`, not in `_process`.

**When to leave GDScript.** Only when the on-device profiler shows one function above `1.0 ms/frame [tune]` that cannot be de-frequencied. Predicted answer for this game: **never** — 13 bodies and ~200 events per shot do not justify a GDExtension build matrix across Android arm64, iOS arm64 and desktop. If `_integrate_forces` genuinely misses budget on the 695, port that one function (rung 2 above) rather than adopting C++ for the module.

**Do not.** Do not write trick-shot detection inside `_integrate_forces`. Do not connect/disconnect signals per frame. Do not use `Dictionary` for `StatMod` (D6 already typed it). Do not reach for C++ before the profiler names a function.

**Acceptance:** on the 695 during a full break, `_integrate_forces` self time `≤ 0.4 ms/frame` and zero script functions above `0.3 ms` self.

---

## 6. Load time & startup

| metric | budget |
|---|---|
| cold launch → Lobby interactive, 695 | `≤ 4.0 s [tune]` |
| cold launch → Lobby interactive, iPhone 11 | `≤ 2.5 s [tune]` |
| Lobby → first playable Round | `≤ 3.0 s [tune]` |
| Round restart (pooled) | `≤ 0.3 s [tune]` |
| first-frame pipeline hitches | `0` visible |

**Measure.** `adb shell am start -W -n <pkg>/com.godot.game.GodotApp` reports `TotalTime`/`WaitTime`; Xcode → Instruments *App Launch*. In-engine: stamp `Time.get_ticks_msec()` at `Lobby._ready` and at the first `Round` frame, log both to the fixture output.

**Techniques, in order.**
1. **Boot into `Lobby.tscn`** (D2), which loads almost nothing. `MainLevel` is never the main scene and never an autoload.
2. **Threaded-load the game under the lobby.** `ResourceLoader.load_threaded_request("res://src/levels/MainLevel.tscn", "", true)` on lobby ready; poll `load_threaded_get_status()` for the progress bar; `load_threaded_get()` on start. Players spend ≥ 5 s in a lobby — the load is free.
3. **Enable the Shader Baker on export** (Godot 4.5+): SPIR-V/MIL baked into the PCK, cutting first-launch compilation. Ubershaders + load-time pipeline precompilation are automatic on the Mobile renderer (4.4+) — but they only precompile for *loaded* resources, so the table, ball and effect materials must be loaded before the Round's first frame, never lazily.
4. **Warm the remaining pipelines behind the fade-in**: one frame with all 13 balls visible and one instance of every `visual_hook` emitter offscreen.
5. **Round restart never reloads a scene** — reposition the pooled balls (D5's Poisson-disk drop) and `reset_physics_interpolation()`.

**Do not.** Do not `preload()` the prop library from an autoload (parsed at startup, blocking). Do not instantiate effect scenes on first use mid-Round. Do not ship uncompressed WAV ambience.

**Acceptance:** on the 695, `am start -W` `TotalTime ≤ 4000 ms` and no frame over 50 ms in the first 5 s of a Round.

---

## 7. Battery & thermal

| metric | budget |
|---|---|
| sustained 60 fps | `≥ 20 min [tune]` without mean dropping below 55 |
| skin temp rise over the soak | `≤ 8 °C [tune]` |
| drain | `≤ 12 %/h [tune]` on a 5000 mAh phone |
| runtime spent at reduced rate | `≥ 50%` (aim time) |

**Measure.** `adb shell dumpsys batterystats --charged <pkg>`, `adb shell cat /sys/class/thermal/thermal_zone*/temp`, Perfetto for CPU frequency + throttle events, `dumpsys gfxinfo <pkg> framestats` for pacing. iOS: Instruments *Energy Log* + thermal state. In-game proxy: a rolling 10 s FPS average driving the quality ladder.

**Techniques, in order.**
1. **Cap the frame rate and keep V-Sync on.** `Engine.max_fps = 60`, `display/window/vsync/vsync_mode = Enabled`. Rendering 90 fps on a 60 Hz panel is pure heat. Biggest single win, one line.
2. **Idle downclock during aim.** When all balls are asleep and the shooter is aiming, nothing moves: `Engine.max_fps = 30 [tune]` and `Engine.physics_ticks_per_second = 60 [tune]`. Restore both on cue strike. At ~9 shots/Round on a 12 s cycle with ~7 s aiming, this is over half of runtime at half rate. Change the tick **only** in the resting state — a mid-motion change hitches with interpolation on.
3. **Free-roam-only frames stay cheap** — players walking the bar while the table is idle need 60 Hz physics, not 240.
4. **Thermal ladder**, one step per 10 s, recovery no faster than one step per minute (prevents oscillation):

| tier | trigger | action |
|---|---|---|
| 0 | default | scale 1.0, MSAA 2×, 60 fps, 240 Hz |
| 1 | mean fps < 55 for 10 s | scale `0.85`, MSAA off |
| 2 | still < 55 | 30 fps cap, 120 Hz tick, ball trails off |

5. **Background/foreground.** On `NOTIFICATION_APPLICATION_PAUSED` (and desktop focus-out): stop network sends, mute audio, `Engine.max_fps = 10`. On resume: restore, then full network resync (§3).

**Do not.** Do not run uncapped in menus or the lobby. Do not lower quality by lowering the physics tick alone — that changes shot outcomes, not heat. Do not keep the socket chatty in the background.

**Acceptance:** 20-minute `perf_soak.tscn` autoplay on the 695 ends with mean fps `≥ 55` and no tier-2 entry.

---

## 8. Asset pipeline

**Texture import presets** (Import dock, saved as presets, applied by folder):

| role | compression | flags | max size |
|---|---|---|---|
| table felt, ball atlas | VRAM Compressed, **High Quality on** → ASTC | mipmaps on | `1024² [tune]` |
| bar prop albedo | VRAM Compressed, HQ off → ETC2 | mipmaps on | `512² [tune]` |
| normal maps | VRAM Compressed, `compress/normal_map = Enabled` | mipmaps on | `512² [tune]` |
| ORM (channel-packed) | VRAM Compressed, ETC2 | mipmaps on | `512² [tune]` |
| UI | Lossless / lossy WebP | mipmaps **off** | source |
| lightmap atlas | engine format, HDR | — | `1024² [tune]` |

Godot's importer maps *High Quality* to ASTC on mobile and BPTC on desktop, and standard to ETC2 / S3TC. Both target GPUs (Adreno 619, A13) support ASTC, so the hero textures get ASTC and everything else ETC2. Changing `rendering/textures/vram_compression` requires deleting `.godot/imported/` and restarting.

**Meshes.** Ball = one icosphere `≈ 320 tris [tune]` with a normal map, not a 5k-tri sphere. Table `≈ 2k tris [tune]`. Whole visible bar `≤ 60k tris [tune]`. Keep importer vertex compression on; import `.glb`, never `.blend` in the shipped project.

**Atlasing.** One 1024² atlas for all `BallType` colours → one material for 13 balls. One atlas for bar props → feeds §2's material budget directly.

**Audio.** Impacts/clicks: WAV import with QOA (or IMA-ADPCM), 22.05 kHz mono `[tune]`. Ambience/music: Ogg Vorbis `96 kbps [tune]`, one stream.

**Export size targets.** Android AAB `≤ 90 MB [tune]` (arm64-v8a only, Play splits the rest). iOS IPA `≤ 150 MB [tune]`. In the mobile export preset enable **ETC2/ASTC only** — leaving S3TC/BPTC on ships both texture sets and roughly doubles the pack.

**Do not.** Do not ship 2048² textures to a phone. Do not disable mipmaps on 3D textures. Do not leave desktop texture formats enabled in a mobile preset. Do not import `.blend` (requires Blender at import time).

**Acceptance:** exported AAB `≤ 90 MB` with no texture asset above `1024²` (CI-checkable, see §9).

---

## 9. Measurement plan & regression gates

**Fixture scenes**, all under `src/debug/`, all runnable headless where the metric allows:

| fixture | measures |
|---|---|
| `perf_break.tscn` | max-power break into 12 balls, fixed seed: Jolt step ms, peak contacts, events per shot, tunneling check |
| `perf_bar.tscn` | full bar + 4 dummy players, camera orbit: draw calls, primitives, GPU frame, fps distribution |
| `perf_effects.tscn` | every `visual_hook` active at once: GPU post cost, particle count |
| `perf_soak.tscn` | 20 min autoplay: thermal, drain, memory drift, orphan nodes |

**Logged every run** via `Performance.get_monitor()` + custom monitors, written to CSV: `TIME_FPS`, `TIME_PROCESS`, `TIME_PHYSICS_PROCESS`, `RENDER_TOTAL_DRAW_CALLS_IN_FRAME`, `RENDER_TOTAL_PRIMITIVES_IN_FRAME`, `RENDER_VIDEO_MEM_USED`, `MEMORY_STATIC`, `OBJECT_NODE_COUNT`, `OBJECT_ORPHAN_NODE_COUNT`, plus `Game/AwakeBalls`, `Game/ContactEventsPerShot`, `Game/NetBytesPerSec`.

**CI (GitHub Actions, no GPU — be honest about the ceiling).** Headless `godot --headless perf_break.tscn --quit-after 600` asserting: no ball outside the table AABB, ball count conserved, contact events `≤ 200`, physics step under the *CI machine's* baseline. Plus two static gates that need no device: exported PCK/AAB size, and no imported texture above `1024²`. **CI cannot measure fps, GPU time or thermals** — those gates are device-only.

**Device farm minimum.** Two physical devices wired to the build machine, not a cloud farm: one Snapdragon 695-class Android and one iPhone 11. Nightly: install, run `perf_bar` + `perf_soak`, pull `gfxinfo` and the CSV, post to the channel. A third device only when tablets ship.

**Gate.** Fail the PR when any fixture metric regresses more than `10% [tune]` against the last tagged baseline, or breaches an absolute budget in §1–§8. Re-baseline only with a written reason in the commit body.

**Acceptance:** every §1–§8 acceptance test runs unattended from one command on both devices and emits pass/fail per budget.

---

## Open questions

- 240 Hz on the 695 is a projection, not a measurement — M0 (P1) settles it. Everything in §1 has a 120 Hz fallback for that reason.
- Ball trails / felt scuff decals are unbudgeted until the effect catalog is final (03 rewrite).
- Free-roam player rendering cost (4 characters, animated) is a Player-module number and is currently a `1.0 ms [tune]` placeholder inside the rendering CPU budget.
- Whether the shot replay (D1/D2 same-machine determinism) needs its own memory budget for stored intents — likely trivial, unmeasured.
