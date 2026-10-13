# Asset credits

Third-party art and audio that ships in the game, with its source, licence and a checksum of the file as downloaded. Prefer CC0; anything
that needs attribution also gets a row in the in-game Credits. Older packs keep their own `SOURCE.md` / `LICENSE.txt` beside them
(`assets/textures/`, `assets/third_party/`).

## Bartender's face (06 P48)

| | |
|---|---|
| What | the head of "Old Guy": brows, eyes, red nose, blushing cheeks, grey handlebar mustache, ear tufts (`assets/models/barkeep_face/`) |
| Author | Polygonal Mind, from their "100 Avatars" set (the atlas inside is named `100Avatars_004_OldMoustache`) |
| Source | https://poly.pizza/m/imEy3Tqg80 (glb: https://static.poly.pizza/878272bc-8915-4949-8c3e-0b7f0f4fba5d.glb) |
| Licence | CC0 1.0 Universal (public domain), as listed on the source page; no attribution required |
| Downloaded | 2026-10-14 |
| sha256 of the download | `399bd6f7b10e6fe63a7f0587078362b58ef96c7ded0743e4532c1a4794c7d285` (`878272bc-8915-4949-8c3e-0b7f0f4fba5d.glb`, 647,848 bytes, 3,364 triangles for the whole figure) |

What the game ships is a cut of it, not the download: `src/tools/build_barkeep_face.gd` keeps the 1,300 head triangles above the neck, turns
them to face -Z, scales them to the barkeep's head and moves them into the head bone's frame (`barkeep_face.res`), and resizes the flat-colour
atlas to 256 px (`barkeep_face.png`). The body, arms and legs are dropped. sha256 of the outputs: `barkeep_face.res`
`e30faf7604a626937860a31c2c0b0ebdc01f32fc2cd2497cc666a93e83e79edf`, `barkeep_face.png`
`61a0f9ecd1e72bfa698dee01cdff1fce2216383e4435fb077ae3559be75d2621`. The face's `StandardMaterial3D` and its attachment are ours
(`src/gameplay/bar/barkeep_face.gd`).
Every third-party asset in `assets/` that is not our own art: where it came from, its licence, when it was fetched. Per-pack licence files sit beside the older kits in `assets/third_party/` and `assets/textures/`. Newer slices append their own section below.

## Audio (adhoc-1014a H, 06 P54-P56)

Everything here is **CC0 1.0** (public domain dedication, https://creativecommons.org/publicdomain/zero/1.0/): no attribution is required, none of it needs an in-game Credits row. We credit it anyway. Fetched 2026-10-14. Budgets (docs/plan/07 §8): SFX <= 1.5 MB, music <= 6 MB, measured in the reply to the task and by `tests/audio/sfx_probe.gd`.

### Music (`assets/audio/music/`, the bar's jukebox)

Downloaded from OpenGameArt (every page's licence field reads CC0), re-encoded by us to stereo Ogg Vorbis ~80 kbps, loudness-normalised (ffmpeg `loudnorm`), trimmed of trailing silence where there was a lot. NCS (NoCopyrightSounds) tracks were NOT used: they are not cleared for games. The jukebox shows "Now playing: title - author" when a track starts.

| File | Title | Author (OpenGameArt user) | Page | Source file | Licence | Fetched | sha256 of the source file |
|---|---|---|---|---|---|---|---|
| `music/technomania101.ogg` | Technomania101 - 2000's europop electronic dance music | Fupi | https://opengameart.org/content/technomania101-2000s-europop-electronic-dance-music | https://opengameart.org/sites/default/files/technomania101_0.ogg | CC0 1.0 | 2026-10-14 | `09180668a2dc1cc64b770d675c034175c558b7ca855736cdac88e048ccf77793` |
| `music/slampe_synthwave_house.ogg` | Slampe - Synthwave House | Fupi | https://opengameart.org/content/slampe-synthwave-house | https://opengameart.org/sites/default/files/slampe_0.ogg | CC0 1.0 | 2026-10-14 | `9953b5f9a16c7a6b54d6ed2bea662006997b43a6946b269b7023c7c9d6929853` |
| `music/cool_city.ogg` | Cool City | MintoDog | https://opengameart.org/content/cool-city | https://opengameart.org/sites/default/files/cool_city_bpm124_0.ogg | CC0 1.0 | 2026-10-14 | `53ab2a4d7ac11e96f94d91a723450240362e2e32b361ee63d72e1e09fffbc784` |
| `music/neon_hyperdrive.ogg` | Neon Hyperdrive | Adiutorium | https://opengameart.org/content/neon-hyperdrive | https://opengameart.org/sites/default/files/neon_hyperdrive.mp3 | CC0 1.0 | 2026-10-14 | `33f33c4dc7fd16076ee44b39eaa8c3f479c72742b5460b8c693cb856e07993b5` |

### Sound effects, made for this project (`assets/audio/sfx/`)

Rendered by `src/tools/make_sfx.py` (numpy, seeded: the same run writes the same files) from sines, noise and envelopes. They are our own work and dedicated to the public domain under CC0 1.0; no sample of anyone else is in them.

| File | What it is |
|---|---|
| `sfx/beam_blip.ogg` | beam materialises one ball |
| `sfx/clack_hard_a.ogg` | ball-ball click, hard hardness |
| `sfx/clack_hard_b.ogg` | ball-ball click, hard hardness |
| `sfx/clack_med_a.ogg` | ball-ball click, med hardness |
| `sfx/clack_med_b.ogg` | ball-ball click, med hardness |
| `sfx/clack_soft_a.ogg` | ball-ball click, soft hardness |
| `sfx/clack_soft_b.ogg` | ball-ball click, soft hardness |
| `sfx/coin.ogg` | a payout clink |
| `sfx/cue_tip.ogg` | cue tip on the cue ball |
| `sfx/ding.ogg` | pot reward bell (pitched by the combo) |
| `sfx/drink.ogg` | a drink served |
| `sfx/fanfare.ogg` | table cleared |
| `sfx/go.ogg` | Round start |
| `sfx/hazard.ogg` | hazard banner siren |
| `sfx/jackpot.ogg` | slot / pocket jackpot fanfare |
| `sfx/lever.ogg` | slot lever ratchet |
| `sfx/lose.ogg` | slot miss, heckle |
| `sfx/lost.ogg` | combo streak lost |
| `sfx/pocket_drop.ogg` | ball dropping into a pocket |
| `sfx/rail_a.ogg` | cushion hit |
| `sfx/rail_b.ogg` | cushion hit |
| `sfx/ready_on.ogg` | GO LIVE pressed |
| `sfx/reel_loop.ogg` | slot reel rattle (loops) |
| `sfx/reel_stop.ogg` | slot reel clicking to a stop |
| `sfx/register.ogg` | purchase, cash register |
| `sfx/time_up.ogg` | clock ran out |
| `sfx/trick.ogg` | trick shot |
| `sfx/trick_minor.ogg` | minor trick shot |
| `sfx/ufo_farewell.ogg` | saucer dematerialises |
| `sfx/ufo_whoosh.ogg` | set-up saucer leaves the vent |
| `sfx/win_big.ogg` | slot big win |
| `sfx/win_seven.ogg` | slot triple seven |
| `sfx/win_small.ogg` | slot small win |

### Sound effects from Kenney packs (`assets/audio/sfx/`)

By Kenney (www.kenney.nl), CC0 1.0 (each pack's own License.txt says so). Re-encoded by `make_sfx.py` to mono 32 kHz Ogg Vorbis, -3 dB. Fetched 2026-10-14.

**ui-audio**: https://kenney.nl/assets/ui-audio , file https://kenney.nl/media/pages/assets/ui-audio/490d233f68-1677590494/kenney_ui-audio.zip , sha256 `946fc23a63d535d693eb31b2eabb80c8c28d6351e2186b344ceb71b2cb1d5eb6`

| File | Original file in the pack |
|---|---|
| `sfx/ui_click_a.ogg` | `click3` |
| `sfx/ui_click_b.ogg` | `click5` |
| `sfx/ui_switch.ogg` | `switch12` |

**interface-sounds**: https://kenney.nl/assets/interface-sounds , file https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip , sha256 `f2193d072726d6758a5f7871b2dcc54dcce0d5c35c6f0a62f92549b327c81232`

| File | Original file in the pack |
|---|---|
| `sfx/ui_confirm.ogg` | `confirmation_002` |
| `sfx/ui_error.ogg` | `error_005` |
| `sfx/chalk.ogg` | `scratch_003` |

**sci-fi-sounds**: https://kenney.nl/assets/sci-fi-sounds , file https://kenney.nl/media/pages/assets/sci-fi-sounds/6b296f9ecf-1677589334/kenney_sci-fi-sounds.zip , sha256 `119340f351a5098ad814f78719438c0da355a9ce8a4c8a3af6a8d48aa3d49e04`

| File | Original file in the pack |
|---|---|
| `sfx/vent_open.ogg` | `doorOpen_001` |
| `sfx/vent_close.ogg` | `doorClose_001` |
| `sfx/trap_open.ogg` | `doorOpen_002` |

**impact-sounds**: https://kenney.nl/assets/impact-sounds , file https://kenney.nl/media/pages/assets/impact-sounds/87b4ddecda-1677589768/kenney_impact-sounds.zip , sha256 `029d734af1582474edf3a694d1b0cebc97c1c152f2f39fa34d4c2bafc5de77f8`

| File | Original file in the pack |
|---|---|
| `sfx/flap_open.ogg` | `impactMetal_heavy_001` |
| `sfx/flap_shut.ogg` | `impactMetal_medium_002` |
| `sfx/trap_close.ogg` | `impactMetal_heavy_003` |
| `sfx/bump.ogg` | `impactWood_heavy_001` |
| `sfx/kick.ogg` | `impactWood_medium_002` |
| `sfx/glass.ogg` | `impactGlass_medium_001` |
| `sfx/lean.ogg` | `impactSoft_medium_001` |

**casino-audio**: https://kenney.nl/assets/casino-audio , file https://kenney.nl/media/pages/assets/casino-audio/2472606a04-1721639069/kenney_casino-audio.zip , sha256 `f36250766ac5bc378c13708ddf12a23a8e54a3251f8d482c7536e51b5dbafa18`

| File | Original file in the pack |
|---|---|
| `sfx/chips_a.ogg` | `chips-handle-2` |
| `sfx/chips_b.ogg` | `chips-collide-3` |

**digital-audio**: https://kenney.nl/assets/digital-audio , file https://kenney.nl/media/pages/assets/digital-audio/216eac4753-1677590265/kenney_digital-audio.zip , sha256 `24e6ce28b76a6d8c89cff4d331e0965ff5c3de8a73c612028e9d363cc64e4f06`

| File | Original file in the pack |
|---|---|
| `sfx/zap.ogg` | `zap1` |

