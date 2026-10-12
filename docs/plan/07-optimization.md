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

*Status (M0):* items 2–6 below and §7.2's idle downclock are implemented (`PhysicsSim.gd`, `Ball.gd`, `project.godot`), at 120 Hz + speed-gated CCD; the 240 Hz hypothesis is still unmeasured (one constant: `PhysicsSim.LIVE_TICK`). Jolt ignores sleep for bodies with `_integrate_forces` — `Ball` sleeps itself at rest (01 §4). **Layers (item 1) are live**: balls layer 1 / mask `1|2|3` (`Ball.tscn`), bed + rails layer 2 (`table_builder.gd`), pocket pot sensors layer 3 (one `Area3D` cylinder per cup, mask 1, not monitorable; the bed's holes, cups and Moving-Pockets covers are layer 2), world/players/bar layer 4 (`BarRoom` collision, `Player.tscn` layer 4 / mask `2|4`); `Interactable` keeps its own layer 6. `tests/physics/layers_probe.gd` proves a world-layer wall does not stop a ball. **Jolt limits trimmed** (`project.godot [physics]`): `max_bodies 512` (was 10240), `max_body_pairs 4096` (65536), `max_contact_constraints 2048` (20480), `temporary_memory_buffer_size 8` MiB (32) — `Memory/Static` with Table + 13 balls: **59.3 MB → 35.0 MB (−24.3 MB)**, measured on the dev PC, deterministic. **Closed by `perf_break` (REQ#perf-2, dev PC, ×20, same metric before/after):** (1) *CCD*: the flat `ccd_speed_mps = 3.0` was tuned at scale 1.0; at scale 2.0 (step 42 mm at 6 m/s vs R 57 mm) 7 balls switched it on. It is now derived, `TableSpec.ccd_speed_mps = 0.8 · R · LIVE_TICK` (5.5 m/s at scale 2.0, 2.7 at 1.0) — peak **7 → 2** (cue ball + one). Probed: CCD off above 7 m/s breaks the round probe's bank shot (rail contact lost), so "never CCD" is not an option. (2) *strike→rest*: a ball spinning in place (`|v| < 0.001`, english ≈ 2 rad/s) skipped `Ball`'s spin bleed and sat awake for 7+ s; the bleed now runs on that branch — max **11.4 s → 6.4 s**, roll-out feel unchanged (`probe.gd` OK). (3) *table at rest*: two causes, both fixed — the six pocket `Area3D` sensors (then drop-zone strips, now cup cylinders; same arming) were stepped by Jolt every tick (**~440 µs**; `Table` now arms them only while `PhysicsSim.active_changed`, host only, clients keep theirs), and a body with `_integrate_forces` never sleeps, so 13 "resting" balls still ran the callback every tick (**~530 µs**; `PhysicsSim` freezes them at `all_resting`, thaws at strike, `Ball.strike` thaws the cue ball before its impulse). Table + 13 balls at rest: **~550 → 8 µs/tick** over an empty scene (`tests/perf/rest_cost.gd`, CI-gated ≤ 50 µs). `perf_break`'s `bodies_active_at_rest` reads 0 either way — that monitor does not count these balls. (4) *live tick*: `TIME_PHYSICS_PROCESS` cannot resolve this (an empty scene reads 0.4–1.1 ms, and it is unusable under `--fixed-fps`); with `--fixed-fps 60 -- --fixed=1` the fixture takes wall/ticks over the shots: **0.63 ms/tick** live, before *and* after the hot-path hoists (`_integrate_forces` itself is ~8 µs/call = 0.1 ms/tick; gravity lookup and `ccd_speed_mps` hoisted, no behaviour change). The old 1.5 ms was the monitor, not Jolt. On the phone the row is the noisy monitor minus baseline; the Profiler decides.

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
1. **Collision layers first — it is free.** 1 `balls`, 2 `table_rails`, 3 `pockets` (Area3D), 4 `world` (players, stools, jukebox), 5 `ragdoll` (a limp player's 11 bones, mask `2|4`: rails + world, never each other, never balls). Ball mask = `1|2|3` only. Free-roaming players and bar props are *never* tested against balls; table-bumping (P2) is a scripted `Effect`, not a collision. This removes 13 × 4 player-capsule pairs × 240 Hz from the broad phase.
2. **240 Hz tick, CCD gated on speed.** At 240 Hz a 10 m/s ball travels `41.7 mm` per step, under the `57.15 mm` ball-ball contact distance — discrete detection holds for ball-ball. It does *not* hold for the pocket jaw cylinders. So: `Ball.continuous_cd` toggled on when `linear_velocity.length() > TableSpec.ccd_speed_mps` (derived: `0.8 · R · LIVE_TICK`), off below. Cue ball keeps it on for the whole shot. Fallback ladder if the 695 misses budget: `240 Hz + gated CCD` → `120 Hz + CCD on all` (120 Hz travels 83 mm/step, CCD is then mandatory) → `120 Hz + max_physics_steps_per_frame 8`.
3. **Sleep aggressively, and use sleep as the shot boundary.** Jolt has its *own* sleep settings: `physics/jolt_physics_3d/simulation/sleep_velocity_threshold = 0.05 [tune]`, `sleep_time_threshold = 0.3 [tune]`. Connect `RigidBody3D.sleeping_state_changed` and count awake balls; zero awake ⇒ `shot_resolved`. This kills the per-frame velocity poll *and* drops the sim to ~0 cost between shots.
4. **Contact monitoring only during a live `Shot`.** `contact_monitor = true` at strike, `false` at rest. `max_contacts_reported = 6 [tune]` on object balls, `8` on the cue. Rails carry `rail_id` metadata (D1) so the ordered contact log is built from the signal, not from a per-step scan.
5. **Physics interpolation on** (`physics/common/physics_interpolation = true`). Cheap insurance for the 30 fps and 120 Hz modes. Call `reset_physics_interpolation()` on Poisson-disk drop and on kitchen respawn or you get streak artifacts.
6. Raise `physics/common/max_physics_steps_per_frame` to `8` so a 30 fps dip does not slow the sim; below that Godot silently stretches time.

**Status (adhoc-1012a, ball feel):** the break now hands the rack's energy on (`BallCollisions`, 01 §3) and the drag is lighter (rolling resistance 0.035 → 0.025, Godot's 0.1/s damping gone), so three rows moved: `perf_break` ×10, same fixture, dev PC — Jolt step live mean **0.209 → 0.216 ms** (the resolver's per-tick cost is inside it; limit 1.0), CCD peak **2 → 3** (the cue ball and two balls the break throws past 5.5 m/s; gate 3), strike→rest max **6.4 → 8.8 s** (gate 10; `RoundDirector.SHOT_CEILING_SEC` is 12). With a cloth multiplier of 0.85 and 0.3° of tilt (the CI modded run; 1° of tilt now beats the lower rolling friction and a moving ball never stops) it is 9.7 s. Table at rest `rest_cost.gd`: 2.3 µs/tick (unchanged); `_resolve_impacts` only runs while a shot is live, host only.

**Do not.** Do not tune `physics/3d/solver/*` or `PhysicsServer3D` sleep-velocity params — **Jolt ignores them**, they are GodotPhysics3D-only. Do not set `continuous_cd` on all 13 balls permanently. Do not raise the tick above 240 Hz "for accuracy" — a 30 fps frame then needs 8 steps and physics doubles per frame. Do not poll velocities at 240 Hz to detect rest.

**Acceptance:** `perf_break.tscn` at max power, 100 runs, zero balls outside the table AABB and mean Jolt step `≤ 1.0 ms` on the Snapdragon 695. The fixture's "Jolt step" is `Performance.TIME_PHYSICS_PROCESS` minus an empty-scene baseline sampled at start — the whole physics tick (engine step + `_integrate_forces`), the closest scripted number; Godot has no Jolt-only timer, and `PHYSICS_3D_COLLISION_PAIRS` reads 0 under Jolt, so contacts/step is counted from `get_colliding_bodies()` (ball–ball once, rails once, bed excluded).

---

## 2. Rendering (Mobile renderer)

Mobile has **no** SSAO, SSR, SSIL, SDFGI, volumetric fog, TAA, FSR2 or auto-exposure. It **does** have MSAA 2D/3D, FXAA/SMAA, glow, depth+height fog, CompositorEffects, PCSS for omni/spot, LightmapGI, 8 omni/spot per mesh and 256 per view. The dim-bar mood is built from baked light + emissive + the Environment's depth fog (P1, P13), not from post-processing.

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
1. **Bake everything static.** `LightmapGI` for the room, emissive materials for the neon/table lamp/TV screens, depth fog from the Environment. Props marked `Static` bake mode. This is the whole "mood" budget.
2. **One shadow-casting light: a SpotLight3D over the table.** A spot shadow is 1 map; an omni is 6 cube faces for the same visual result. Atlas `2048`, spot quadrant `1024 [tune]`. Only balls, cue and players cast into it; every prop is `shadow_casting = Off` and baked instead.
3. **One ball material.** A single 1024² ball atlas + `set_instance_shader_parameter()` for per-ball colour keeps all 13 balls on one pipeline. 13 draw calls is not a problem — go `MultiMeshInstance3D` only if the draw-call monitor actually breaches 120.
4. **Merge the bar by material** into `≤ 8 [tune]` static meshes; `visibility_range_*` (LOD/fade) on stools, bottles and the far wall.
5. **MSAA 2× 3D**, no FXAA. Tile-based GPUs resolve MSAA in tile memory (near-free at 2×); FXAA smears the felt texture and fails exactly on the thin cue stick. `4×` on iPhone 11 only.
6. **`visual_hook` effects are one ubershader on one fullscreen `ColorRect`** — vignette, `lights_out` darkening, drunk-wobble UV offset, `crowd_roar` flash all as branches on float uniforms, mixed in a single pass. Never stack one pass per active Effect.
7. **Render scale `0.85 [tune]`** (`rendering/scaling_3d/mode = bilinear`) as the first thermal lever; FSR2 is not available on Mobile.
8. **`rendering/viewport/hdr_2d = true`.** The Mobile 3D buffer is RGBA8 *linear*: a dim room quantises into 1/255-linear steps, i.e. sRGB levels 8 / 15 / 20 / 25 / 29 near black. That was the swirling "blotchy" walls and ceiling of the first bake (not the lightmap: the EXR holds 11k distinct values) and it also lifted every dark pixel to level 8. `hdr_2d` switches the buffer to RGB10_A2, the same 4 B/px and a Vulkan-mandatory format, so it costs nothing in bandwidth. 2D then blends in linear space (UI alpha reads very slightly lighter). With the true levels the room needed its baked light energies raised (neon 24, room fill 28, jukebox 12, TV 24, bar fill 3).

**Do not.** Do not enable occlusion culling — one room where nearly everything is visible costs more CPU raster than it saves. Do not read `hint_screen_texture` with a mipmap filter (forces a screen copy + mip chain every frame). Do not add a second shadow-casting light "for the bar". Do not run uncapped above the panel rate.

**Modes:** `60 fps` (default) / `30 fps` battery / `120 fps` PC only. The 30 fps mode **must** also drop the physics tick to 120 Hz — otherwise it is 8 Jolt steps per frame and saves nothing.

**Status (M0):** the room is `src/gameplay/bar_room/BarRoom.tscn` (built by `src/tools/build_bar_room.gd`, baked by `src/tools/bake_lightmaps.sh`; screenshots `docs/plan/img/bar_room_*.png`): 8 merged static meshes (11 surfaces / 11 materials; the wainscot has its own so a `BarSkin` can tint it), UV2-unwrapped, `LightmapGI` (interior, medium, 2 bounces, denoised, 1 atlas `256×1024` HDR), emissive neon ×2 / TV / jukebox glass, **2 realtime lights, 1 shadowed** (`TableLamp` SpotLight3D + `BarFill` omni) plus 5 baked-only omnis, `WorldEnvironment` (exponential depth fog, filmic, glow low; the three fog-plane quads were removed, P13), 2 `ReflectionProbe`s, MSAA 2×, occlusion culling off. Deviations, all deliberate: (a) Godot 4 has **no baked-reflection asset** — the probes are `UPDATE_ONCE` (captured at load, 128² atlas, 4 slots); (b) tier 0 keeps the 07 §7.4 scale `1.0` — `0.85` is tier 1 *and* the frame-budget baseline, so `perf_bar` runs at `0.85` by default; (c) every room mesh is `cast_shadow = off` (props never enter the one shadow map, they are baked). `LightmapGI.bake` is not in the scripting API: the bake presses the editor's Bake button through a temporary editor plugin (`src/tools/bake_plugin`, enabled only by the script). Two cheap wins found by `perf_bar`: the default reflection atlas (256², 64 slots) alone was **~250 MB** of texture memory — trimmed to 128² × 4 (`RENDER_TEXTURE_MEM_USED` 296 → 53 MB, room + table); `TableVisuals` now merges its 63 meshes into one per colour (draw calls 73 → 17, look unchanged).

**Status (adhoc-1010a, bar decor + table glare):** the room gained `Decor` (`src/gameplay/bar_room/decor_plan.gd` is the placement list, `build_bar_room.gd` bakes it): 22 prop models (CC0 Kenney Furniture / Survival / Food kits, licences in `assets/third_party/<pack>/LICENSE.txt`, source `.glb` kept out of the PCK by a `.gdignore`) and 10 posters + a dartboard (our art, `src/tools/make_posters.py` -> `assets/decor/poster_atlas.png`, 1024², one atlas) merged into **one static, UV2-unwrapped mesh with one material** (atlas texture × vertex colour; untextured props sample a white atlas strip, so props and posters share the material). Measured with `perf_bar --seconds=20` on the dev PC, base `8929773` vs this change, same session: draw calls p95 **92 → 93**, primitives max **25,700 → 30,858** (+5,158), texture memory max 61.0 → 61.6 MB, unique materials in the bar **11 → 12** (at the `≤ 12 [tune]` limit — the next prop family needs an atlas slot, not a material), exported PCK (`Android M0` pack) **1.56 → 2.61 MB** for the decor alone (poster atlas ETC2 + 330 KB mesh + the bigger lightmap), **4.87 MB** for the whole card (icons, bar-skin previews, new scenes; `tests/perf/baseline.json` re-baselined with the reason, 05 §9), no light added. **Open, needs Cleanse:** the room fixture holds 12 materials (at the `≤ 12 [tune]` limit), and MainLevel adds 5 dynamic ones outside it (blackboard 2, GO LIVE pedestal 2, mirror 1). Draw calls with all of them in view measure p95 ≤ 100 (`src/tools/perf_mirror.gd`, dev PC), but whether the limit should become 17 or the props should be atlased waits on the phone run (`m0_device_run.sh`). `frames_within_vsync_pct` read 78% on **both** trees: the dev PC runs five Godot panes at once, so that row is not a signal here; the phone gate (`m0_device_run.sh`) is. Floor props collide (layer 4 boxes from the model footprint); the generator and `tests/world/bar_room_probe.gd` both reject any prop or poster in the keep-clear zones (table + 1.6 m band, door, counter + aisle, jukebox, tables, blackboard, mirror, GO LIVE spot, every `Bar.PROPS` reach zone). Table glare (C8): the cushion rubber, felt and rails shared the engine default `metallic_specular 0.5`, a white lobe from the table lamp that is independent of albedo — about half of the near-black cushion's lit brightness (median 0.07 → 0.03, p95 0.27 → 0.15, peak 0.63 → 0.25 in the 4 test views; `TableVisuals._material` is now matte, `metallic_specular 0`).

**Status (adhoc-1011a, real pockets, table rows; 06 P30–P32):** every pocket is a hole in the bed and the cloth with a cup under it (01 §2 "Pocket geometry"). Measured on the dev PC against `883608c`, same session, table node alone: **draw calls 12 → 7** (the six liner cylinders merged into the one dark-colour mesh; **13** while Moving Pockets is live: +6 cover rings that must move on their own, −5 merged liners, so +1 over the old table in the worst case), **triangles 5,220 → 1,556** after the seam and jaw-tip closing (2,850 with covers measured before it), **collision shapes 30 → 324** in 20 bodies (bed 21 convex pieces in one body, 6 cups of ~55 prism walls; 783 shapes / 26 bodies with the 6 covers, built only while a Moving Pockets Effect is live and rebuilt only when `pocket_radius_mult` or the amplitude changes — at Round setup, never mid-shot). Table + 13 balls at rest `rest_cost.gd`: **2.5 → 2.5 µs/tick** (limit 50); `perf_break` ×10: Jolt step live mean **0.217 → 0.209 ms** (limit 1.0), events/shot max **48 → 46** (limit 200), strike→rest max 6.35 → 6.39 s, contacts peak 23 → 22, CCD peak 2, nothing off the table. SYNC's break fixture (`simdiff_probe`): plain break events **192 → 197–199 against the 200 budget** (the lip crossing and the cup landing of each pot ride the divergence stream: ~6 more events per break) and the modded break **291 → 298** (cap 400, client error 2.6 → 4.4 mm against the 5 mm gate); `BallMotion` now drops a ball under the cloth plane onto the cup floor instead of leaving it on the cloth until `pocket()`, which is what keeps the count there. No new codec flag, no new `@rpc`. The plain-break budget was raised to 220 (alpha, adhoc-1011a) for that headroom; host upstream stays under its 16 KB/s gate. **Open, needs the phone:** the run (`m0_device_run.sh`) decides the collision-shape count (324 static convex shapes is far below Jolt's limits but is 10× the old table).

**Shadow atlas (P32):** `project.godot` had `positional_shadow/atlas_quadrant_0_subdiv = 2` (four 512² slots) for the one shadowed light, against this document's "spot quadrant 1024" (§ "One shadow-casting light"); it is now `1` (one 1024² slot, atlas size unchanged at 2048) and `TableLamp.shadow_bias` is `0.01` (was `0.04`: 6 texels of peter-panning at 6.4 mm/texel put the rail and cushion shadows away from their bases; `build_bar_room.gd` follows). Cost of the 1024² slot against the 512² one (`perf_bar --seconds=20`, same session, dev PC): `gpu_frame_mean` 1.053 → 1.076 ms (+0.02), p95 2.257 → 2.287 ms, texture memory 61.63 MB both (the 2048² atlas is allocated either way), draw calls p95 83 both; the phone is unmeasured. Bias sweep (bias 0.04 / 0.015 / 0.01 / 0.005 × `shadow_normal_bias` 0.5 / 1 / 2, `screenshot_table_seams.gd acne=1`, phone tier): cloth pixel noise 0.00056 in all twelve (no acne) and nose-base seam ratio 0.56 in all twelve, so the bias moves no seam number; `shadow_normal_bias` stays at the engine default 1.0. Specular: `lamp_specular=0` changes no seam luminance (identical to 4 digits, the materials are matte) and dropping every `ReflectionProbe` changes the rail top by ≤ 8 % (diffuse ambient), so neither can be the glare. Seam luminance (`src/tools/screenshot_table_seams.gd`, 7 poses + 3 close-ups, seam ÷ adjacent cloth, limit 1.1): nose-base worst **0.65 before, 0.57 after** (nose top ≤ 0.15, groove ≤ 0.08), tier 0 and the phone's tier 1/2 (no MSAA, 0.85 scale) alike; shadows on/off and bias 0.04/0.005/0 move it by < 0.06 — the desktop render never showed a bright seam, **so the phone-only glare is not reproduced here; the phone check is pending the next APK test.**

**Cracks (P32, A#glare-1):** `screenshot_table_seams.gd leaks=1 [sweep=1] [jitter=<mm>]` renders the table alone over a magenta and then a cyan backdrop: a pixel that changes is backdrop, i.e. the room behind the table, and a patch of it that the table's silhouette encloses (or a run thinner than 6 px) is a crack. Views: the 10 seam poses (7 player poses + 3 jaw close-ups), a high and a low close-up of each of the six pockets (22 in all) and (`sweep=1`) an orbit of 24 azimuths × 3 heights. `jitter` shifts every visual mesh by up to that many millimetres per axis, a stand-in for a phone GPU's rounding. The committed P30 pockets leaked **8,180 px over 22 views**, all of it a `bed_thickness_m` slit round the rear of every side pocket (the back wall started at the cloth plane, the liner ring stopped under it); the room showed through as a bright arc. Now **0 over 94 views at jitter 0 / 1 / 2 / 4 mm** (and at 4 mm under 9 more random jitter seeds). Jitter 1 / 2 mm had left 2 / 4 single-pixel specks, all at the side-pocket jaw tips, where cloth rim wall, cushion, facing, apron, liner and rail block all met on one vertical line; adhoc-1011a closed them (see below). The base `883608c` has none along cushion, cloth or rail at jitter 0 / 1 / 2 mm, only a few dozen pixels at the side-pocket mouth. The rule behind the fix: no visual seam is an edge-to-edge contact. The cushion wedge and the facing stubs run `bed_thickness_m / 2` below the cloth plane with their slope carried on into the rail block, each rail block has an inset plug into the apron under it, the pocket liner stands `bed_thickness_m / 2` behind the cloth's own rim wall (the cloth overhangs it, so a mesh a few mm off cannot bring it in front of the wall and open a slot to run down and out under the cloth) and reaches `/ 2` under the cloth plane, and the back wall starts 1.5 slabs down. The jaw-tip pass (adhoc-1011a, `table_visuals.gd`) added three more: the cloth's top edge and rim wall end `2 x bed_thickness_m` inside the cushion (`_tucked`: the end vertex is moved, not added, because a vertex in the middle of a shared edge is a T-junction and a pinhole in the cloth), each side-pocket rail block runs `bed_thickness_m / 2` on into the pocket (the pocket's back wall used to meet its corner edge tangentially), and each leg runs `/ 2` up into its apron. A crack in any of those shows dark rubber, wood or liner, never the room. The checker's open-background flood is 8-connected: the tip of the window under the apron beside a leg was one pixel off the rest of it diagonally and read as an enclosed hole at 4 mm. Mesh count and draw calls are unchanged (7 table meshes; the plugs merge into the rail colour); triangles 1,380 → 1,556 for the overlaps (measured on `Table.tscn`, budget ≤ 60k). Desktop seam ratio still 0.57 worst (phone tier 0.56).

**Status (adhoc-1012a, bar art):** every surface of the room and the table is now PBR on CC0 Poly Haven sets (`assets/textures/<set>/{albedo.webp, orm.webp, normal.png}`, fetched and normalised by `src/tools/make_textures.py`, licence + sources in `assets/textures/{LICENSE.txt,SOURCE.md}`): brick wall, plank floor, panelled wainscot / counter front / back bar, dark wood, leather, metal plate, ceiling, velvet felt. The albedos are *detail maps* (desaturated, mean linear luminance 0.7, the felt 0.9) multiplying the material's `albedo_color`, so a BarSkin colour is still set verbatim (`BarRoom.apply_skin` unchanged, `skins_pair_probe` unchanged) and only gains grain. The room mesh is box-mapped in world metres by `build_bar_room.gd` (UV = position / tile on each face's dominant axis; floor 2 m, brick 1 m, panels 2.1 m, wood 1.2 m, leather 0.5 m, metal 1 m), so nothing stretches and no shader or triplanar cost is paid. Materials are `ORMMaterial3D` (albedo + one ORM read + normal; the ceiling has no normal map): **the room stays at 12 materials** and its 12 draw calls, because the Kenney props are no longer one flat-colour surface: `DecorPlan.classify` routes each *triangle* by its palette colour to the room's own `wood` / `seat` / `prop` surface (or, for greens, yellows, rugs and the posters, to the one atlas surface), so shelves, sofas, barrels and appliances carry the room's textures and recolour with the skin. The brass foot rail, door handle, taps and jukebox trim are vertex-coloured `prop` metal (its material is white). New geometry, all inside the old collision footprints: lathe-turned round tables and bar stools, brass foot rail, 21 shelf bottles + counter glasses (Kenney Food / Survival), neon as real tubes on backing plates (sized to `DecorPlan.wall_keep_clear`'s sign rects), a green pool-hall shade, panelled door, base / chair-rail trim, a jukebox with an arched crown, three beer taps; the wall TV shows a generated pool broadcast (`make_tv.py`, emission texture). The table: felt albedo + nap normal on the cloth (still a `StandardMaterial3D`, `albedo_color` is the felt colour), rails / apron / legs / horns on one wood PBR mesh, rubber and sights one flat mesh, liners their own: **table materials 7 -> 4, draw calls 7 -> 4**, geometry untouched (1,556 tris, 0 cracks over 22 views at jitter 2 mm, seam ratio 0.57 worst). Measured with `perf_bar --seconds=20` on the dev PC against base `bd1f958`, same session: draw calls p95 **83 -> 77**, primitives max **23,530 -> 31,496** (room 8,866 -> 16,832 tris), texture memory max **61.6 -> 67.8 MB** (desktop BPTC/S3TC; the phone's ETC2 / ASTC are about 0.5-0.6 of that), `gpu_frame_mean` 1.13 -> 1.15 ms, unique materials in the bar (room + table) **19 -> 16**, exported PCK (`Android M0`) **4.87 -> 10.64 MB** (the sets are 6.3 MB of it: felt ASTC HQ 1024, floor ETC2 1024, the rest 512 / 256; `tests/perf/baseline.json` needs re-baselining for this reason, 05 §9). Lightmap re-baked (`BarRoom.exr` 0.72 -> 0.92 MB), the five bar-skin previews re-rendered and switched to lossy WebP (the textured rooms made their lossless PNGs twice as big). Not tried: the room's static light is baked, so the normal maps only answer the two realtime lights (table lamp, bar fill); a Poly Haven prop (crate, pendant lamp, 5-10k tris each, stool 8.3k and unsimplifiable: thin rods) would need its own material and a decimation pass. **Open, needs the phone:** the fill cost of 3-4 texture reads on the brick and plank pixels at scale 0.85, and whether `anisotropic_filtering_level` should go from 2 to 4 for the floor at grazing angles.

**Slot machine (adhoc-1012a):** the bar slot (02 §3.9) is a dynamic prop under `Bar`, not in the lightmap: **one new material** (`slot_machine.gdshader`, shared by the cabinet, 61 bulbs, the lever and the three drums; one 1024×64 symbol atlas, 14 KB in the PCK, mipmapped at load: 0.34 MB of texture memory) — **the bar's dynamic materials go 5 → 6** (MainLevel's blackboard 2, pedestal 2, mirror 1, slot 1), which feeds the open "≤ 12 or atlas the props" question above — and **5 meshes + 3 `Label3D`** (1,308 triangles: body 1,032, lever 132, drum 48 × 3, the drum mesh is shared). Measured (`src/tools/screenshot_slot.gd` camera, the machine a third of the view, dev PC, same session): draw calls **33.8 → 41.2** idle (+7.4) and 43.9 spinning with a win pop up (+10), primitives **12.9k → 14.6k** idle (+1.7k), texture memory unchanged in this comparison (102.86 MB both: the machine is loaded in both runs, so only its 0.34 MB atlas is not shown). No light, no shadow caster (`cast_shadow = off`), no particles; the only per-frame work is `SlotMachine._process` while a spin or its celebration runs (≤ 6.3 s, then `set_process(false)`), 3 `rotation.x` writes and 3 instance-uniform writes. The phone is unmeasured.

**Status (adhoc-1012a, chaos FX; 10):** `ImpactFx` pools everything it shows: 14 `GPUParticles3D` + 12 pop quads + 6 `Label3D` + 3 `GPUParticles2D` + 3 banner labels + one flash `ColorRect`, one shared `OmniLight3D` (third realtime light, no shadow, off on tier 2) and no new materials in the bar (the FX use their own two shaders, additive, no screen-texture read: still one post pass). Idle = no process. Worst-case storm on the dev PC (`tests/fx/fx_cost.gd`, 4 hits per frame + a pot per 0.4 s + a trick per 2.5 s, 1280x720): GPU +0.10 ms at tier 0/1, +0.02 ms at tier 2; draw calls +37 / +28 / +20 over a bare table (18). Tiers cap hits per frame (6 / 4 / 2) and the share of each pool in use (1.0 / 0.6 / 0.35). Phone cost not measured yet: `m0_device_run.sh`, then re-check `draw calls <= 120` with the bar, the mirror and a trick celebration on screen at once.

**Status (adhoc-1012a, playtest):** the chaos tuning added no pool and no material: the new beats (hazard, Drink, GO, cleared, Pocket Jackpot ring, Flaming Shot embers) reuse the banner rows, one pop quad, one `Label3D` and the fountain / light slots, so `tests/fx/fx_cost.gd` is unchanged (storm tier 0: +0.110 ms GPU, +37 draws). The autoplay bot (`src/tools/playtest.gd`, 10 §8) measured draw calls at the aim over 90 shots on the dev PC (3 seeds): median 111, p95 122, max 131, 9 shots over the 120 limit (11 with the build before the chaos tuning): bar + mirror + slot + HUD, not FX (FX idle at the aim); the phone re-check in the line above stays open.

**Acceptance:** `perf_bar.tscn` orbit, 60 s on the 695 — `≥ 95%` of frames under 16.6 ms, draw calls `≤ 120`. "Under 16.6 ms" is read as *no missed 60 Hz vsync*: a frame passes at `≤ 16.6 + 1.0 ms` (timer jitter); a missed vsync is 33 ms.

---

## 3. Netcode

Event-based sync per D2, ENet + Noray primary per P1. Mobile radios punish *packet cadence*, not bytes.

| metric | budget |
|---|---|
| contact event, packed | `16 B [tune]` |
| events per `Shot` | `≤ 200 [tune]` (SYNC's plain-break fixture `≤ 220` since real pockets, 06 P30: every pot's lip crossing and cup landing ride the divergence stream, measured 197–199); `≤ 400 [tune]` while table-stat Effects are live (cloth 0.7 + tilt 1° measured 298 by SYNC — the model diverges from Jolt more often). Hard gates are unchanged: host upstream `≤ 16 KB/s`, `30 Hz` flush |
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

**Status (M0):** `QualityManager` (`src/gameplay/quality/`, a `MainLevel` child; ladder logic is the pure `QualityLadder`, `tests/perf/quality_probe.gd`). `Engine.max_fps = 60` + vsync via project settings; idle = table at rest (`PhysicsSim.all_resting`) and no input event for 2 s → 30 fps, any input wakes to 60 instantly (`keep_awake()` for pose/effect sources; tick stays `PhysicsSim`'s: `REST_TICK` 60 at rest). Ladder: 10 s mean-fps window (idle/paused frames excluded), `< 55` (`< 27.5` at a 30 fps cap) steps down; recovery one step after ≥ 60 s dwell with mean ≥ 96% of target, dwell doubles (cap 8 min) if a recovery is undone within 30 s. 30 fps battery setting = `battery_mode`. `NOTIFICATION_APPLICATION_PAUSED` / focus-out → mute bus 0, `max_fps 10`, signal `app_paused`; resume restores and emits `app_resumed` (NET/SYNC hook these for the resync). Tier 2's 120 Hz live-tick cap is `QualityManager.tick_cap(base)`; `PhysicsSim._on_struck` must call it once `LIVE_TICK` goes above 120 (SYNC's file, no-op today).

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

**Status (M0):** `src/tools/check_gates.gd` fails on any image above `1024²`, on a mobile (Android/iOS) preset with S3TC/BPTC on, on `import_etc2_astc` off, and on a PCK over 90 MB or > max(10%, 2 MB) above `tests/perf/baseline.json` (re-baseline only with a written reason). `Android M0` presets ship arm64 only (`Android M0 emu`: x86_64 only, smoke) with `gradle_build/compress_native_libraries=true` — the sideload debug APK drops from 84 MB (uncompressed `libgodot_android.so`) to 33.7 MB. The AAB gate itself needs a release build; until then the APK size is printed by `m0_device_run.sh`.

**Status (adhoc-1012a, bar art):** the room's PBR sets follow the table above (importer presets written by `make_textures.py`, never hand-set): `compress/mode=2` VRAM + mipmaps on everything, ASTC (`high_quality`) for the felt only, ETC2 for the rest; albedo 1024 (felt, floor) or 512, normals 512 / 256, ORM 512 / 256, all `compress/normal_map=1` on the normals; Pillow downscales the 1k downloads. `bar_room_probe` checks the flags, the licence files and that the room stays within 12 materials. The bar-skin preview panoramas (`assets/ui/bar_preview`) are lossy WebP (quality 0.85) so a textured room does not double their share of the pack.

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

**Status (M0).** Fixtures live in `src/debug/perf_*.tscn` (base `PerfFixture`, recorder `PerfLogger`): CSV of the monitor list above every 0.25 s to `user://perf/<fixture>-<ts>.csv`, plus a PASS/FAIL/INFO/SKIP row per budget (`PERF|fixture|budget|value|op limit unit|status` on stdout, `summary.csv`). GPU time comes from `RenderingServer.viewport_get_measured_render_time_gpu`; under `--headless` render rows print `SKIP`. `perf_break` args: `--runs=100 --seed --balls=12 --fixed=1 (with godot --fixed-fps 60) --cloth=0.7 --tilt=1.0 --step-limit-ms` (the fixture counts contact events; SYNC's NetGraph counts the stream); `perf_bar`: `--seconds=60 --scale=0.85`; `perf_effects`: `--seconds=30` (ViewOverlay ubershader at full uniforms, 8 particle bursts, 4 decals); `perf_soak`: `--minutes=5 --aim=6` (real `QualityManager` in the loop). `perf_sequence.tscn` runs all four; the `m0` export feature boots it (`run/main_scene.m0`).

**One command on the phone** (USB debugging on, `adb devices` lists it; no phone → it stops with that message):

```
src/tools/m0_device_run.sh                 # 100 breaks + 60 s orbit + 30 s effects + 5 min soak, ~25 min
src/tools/m0_device_run.sh --soak-min 20   # the §7 acceptance soak
src/tools/m0_device_run.sh --quick         # 2-minute pipeline smoke
src/tools/m0_device_run.sh --emulator      # AVD smoke; numbers are not budgets
```

It exports the `Android M0` preset (gradle, arm64), installs, launches with `am start -W` (`TotalTime` vs §6), waits, samples `dumpsys meminfo` RSS and thermal zones every 10 s, captures a SurfaceFlinger latency window during the orbit (Godot's Vulkan surface bypasses HWUI, so `dumpsys gfxinfo` framestats stay empty — the dump is saved anyway), pulls the CSVs with `run-as` into `build/m0/<ts>/` and prints the budget table + `M0 RESULT`. Drain is only valid unplugged (USB charges); use wireless adb for the §7 drain number.

**CI** (`.github/workflows/ci.yml`, no GPU): all probes + the pair probe (`tests/run_all.sh`), `perf_break --ci=1` (gates: no ball off the table, ball count conserved, events/shot ≤ 200, a coarse step ceiling), Android-preset PCK export + `check_gates.gd`. Device-only budgets are printed as INFO in CI.

**Dev-PC reference (i7-11800H + RTX 3050 Ti Laptop, other agents running — never a sign-off):**

| fixture | budget row | dev PC | 07 budget |
|---|---|---|---|
| `perf_break` ×20 (`--fixed-fps 60 -- --fixed=1`) | physics tick live, wall/ticks (ms) | 0.63 (before 0.64) | ≤ 1.0 |
| | physics tick at rest over empty (µs, `rest_cost.gd`) | 8 (before ~550) | ≤ 50 |
| | contacts per step (peak) / CCD bodies (peak) | 23 / 2 (before 7) | ≤ 40 / ≤ 2 |
| | events per shot (max, contacts) / strike→rest (max) | 47 / 6.4 s (before 11.4) | ≤ 200 (≤ 400 with table-stat Effects) / ≤ 9 |
| | balls off table or fell / ball count delta | 0 / 0 | 0 |
| `perf_bar` 60 s, scale 0.85, MSAA 2× | frames within vsync | 99.9% | ≥ 95% |
| | draw calls p95 / primitives max / nodes | 87 / 25.7k / 173 | ≤ 120 / ≤ 60k / ≤ 1500 |
| | GPU frame mean / p95 (ms) | 1.76 / 2.69 | ≤ 13.0 |
| | texture mem / `Memory/Static` (MB) | 44 / 63 | ≤ 180 / ≤ 260 |
| | slowest frame in first 5 s (ms) | 26 | ≤ 50 |
| `perf_effects` 30 s | GPU frame mean (ms) / frames within vsync | 1.82 / 99.5% | ≤ 13.0 / ≥ 95% |
| `perf_soak` 2 min | active-frame fps / deepest tier / orphans | 59.9 / 0 / 0 | ≥ 55 / < 2 / 0 |
| | `Memory/Static` drift Round 1→5 / reduced-rate share | +0.04% / 48% | ≤ 5% / ≥ 50% |

The `perf_bar` / `perf_effects` / `perf_soak` rows are from REQ#perf-1 (real time, window open). The emulator smoke (`--emulator`, Compatibility renderer, software GL) reaches every row of the table and proves the pipeline; its fps/GPU rows are meaningless.

**Acceptance:** every §1–§8 acceptance test runs unattended from one command on both devices and emits pass/fail per budget.

---

## Open questions

- Tier 0 scale: 07 §7.4 says 1.0, the frame budget is written at 0.85. If the 695 misses at 1.0, tier 0 becomes 0.85 (`QualityManager.TIERS[0]`, one line).
- 240 Hz on the 695 is a projection, not a measurement — M0 (P1) settles it. Everything in §1 has a 120 Hz fallback for that reason.
- Ball trails / felt scuff decals are unbudgeted until the effect catalog is final (03 rewrite).
- Free-roam player rendering (4 characters, animated): **budgeted, desktop-measured, phone unmeasured.** (06 P26: the arms moved onto the body mesh so the local player can see them; the head surface alone is culled from the local camera — still 2 meshes, still 5 draw calls per avatar. The Bartender's barkeep look is the same two meshes. The material is a 12-line spatial shader (`humanoid.gdshader`, vertex colour + a fill) instead of a `StandardMaterial3D`: still one material for every avatar.) Per `Humanoid` (08 §2.7): 11 bones, **548 triangles**, one vertex-coloured material shared by all, **2 draw calls** (body, head + hat) + 2 in the spot's shadow pass + 1 `Label3D` tag = **5/avatar** (`RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME`: 75 → 100 for five avatars). Animation is GDScript on 11 bones: **19 µs per Humanoid per frame** on the dev PC (4 → 77 µs), ~5–8× on the floor phone ≈ `0.5 ms` for four, inside the `1.0 ms [tune]` placeholder. Physics: **0** while idle (the 11 physical bones are on layer 0 and not simulating), 11 rigid bodies + 10 joints per limp player for ~2 s; the working budget is `≤ 2` limp players at once `[tune]` (`≈ 22` extra bodies, no CCD, no self-collision). **The wall mirror (06 P26, 08 §2.7)** adds a second view of the room, table and avatars while its glass is on screen: ~30 draw calls in the frames that render it (20 Hz, 10 Hz on tier 2, only within 8 m, `576×384`, no MSAA, no shadow atlas), `0.08–0.14 ms` GPU on the dev PC; `src/tools/perf_mirror.gd` (real MainLevel, five humanoids): draw calls p95 `100` mirror in view / `101` out of view, ≤ 120. Phone unmeasured. Unmeasured: the Jolt row above is the table alone, so `perf_bar` must add a knock to its fixture before this is signed off.
- Skins (06 P18): the Skins screen's preview is one `Humanoid` in an own-world `SubViewport` that renders only while the screen is open (a main-menu screen: nothing of it exists in a session's frame). A bar skin swap is seven shared-material colour writes plus the felt's, once per Round, with no per-frame work and no new draw calls; an avatar re-skin rebuilds ~1k vertices once at spawn.
- Whether the shot replay (D1/D2 same-machine determinism) needs its own memory budget for stored intents — likely trivial, unmeasured.
