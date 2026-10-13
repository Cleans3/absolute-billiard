# 09 — Story: "The Last Table"

## 1. Purpose

This doc gives the debt loop (02) a reason and a face. The crew did not choose this: the Rope took them, hooded and gagged in a van, to a
cabin in the woods that hides *Gus's Corner Pocket*, and bolted the door. Velvet Moe owns the stream and the house's quota, Gus (the
bartender) is as stuck as they are, and the stream is how Moe wants to be paid. Fail the quota and the house keeps you; make it and you are
gassed and trucked out (06 P39, adhoc-1013c D12).

The story is told through what the game already has (the bartender's lines, the walls, the blackboard, the phase screens) plus, since P39, a
small set of **cutscenes** (§3.8, §4.4) for the three moments that change the room: the arrival, the failure and the win. **No rule
changes**: a cutscene never decides an outcome, it presents one the host already reached.

## 2. Concepts & data model

### 2.1 The cast

| who | what they are | where the player meets them |
|---|---|---|
| **The crew** | 1–4 amateur players abducted off the street (the cutscenes never say why). They are never named; players bring their own names. | everywhere |
| **Gus** | The bartender and owner of *Gus's Corner Pocket*. Moe's prisoner as much as the crew's host: he has been here since 1979 and the bar is older than the cabin. He lets amateurs stream on his only table because a crew paying Moe in public keeps Moe off *his* back. His sarcasm is fear in a bow tie. | behind the counter (P24 body, `bartender_*`) |
| **Velvet Moe** | A loan shark who works out of pool halls. He is never seen, only heard: on the phone, in the ledger, in the stream chat as "velvet". He takes his money **on stream**, because a debt paid where the whole city can watch teaches the city something. | the phone behind the bar, the wanted poster, the Reckoning, the chat |
| **The Rope** | Moe's collectors: they abduct, they drive the van, they "help". They are the in-world source of the hazards. | the intro, Event flavor lines (§3.4) |
| **The thing under the floor** | What the house does with a crew that misses. Never named, never seen until the failure fall. | Gus's nervous lines, the floor by the table |

### 2.2 The place

From the road: a log cabin in a clearing, a porch light, a hand-painted board "GUS'S CORNER POCKET — est. 1979". Inside, bigger than the
outside should allow: the room we already have (`BarRoom`), with the story in its details:

- A **wanted-style poster of Moe**, defaced to read "VELVET MOE — DO NOT ASK" (the face scratched out). It takes the "live band" poster's
  slot on the west wall (same atlas cell, so no new material and no layout change).
- A **"Gus's Corner Pocket — est. 1979" sign**: the 2-wide banner over the entrance (north wall), replacing "open late". The door under it
  is bolted from outside; there are no windows.
- A **wall phone** behind the counter. It rings once per Night (§3.2).
- The **blackboard's debt line** reads as Moe's demand (§3.5).
- A **vent** in the ceiling above the table's east end, a **trapdoor** in the open floor, and a **mirror** on the west wall: the hardware of
  the cutscenes (W5 builds the vent and trapdoor, W3 the bloody mirror; §3.8).

### 2.3 Data

One resource per campaign Night. Endless Nights reuse one shared resource.

```
StoryNight (Resource)          src/resources/story/story_night.gd
  night: int                   # 1..3; 0 = the Endless resource
  intro_cards: Array[String]   # shown at NIGHT_START, before Intermission; [] = none
  call: Array[String]          # Moe on the phone, one subtitle per line; [] = no call this Night
  gus_lines: Array[String]     # extra ambient lines for Gus, unlocked from this Night on
  paid_line: String            # Reckoning line when the Quota is met (Night 3 reads it in Endless only)
  short_line: String           # the failure line for this Night (the caption over the black after the fall)
  chat_line: String            # one stream-chat message from the viewer "velvet" (§3.7)
  ending_cards: Array[String]  # the finale's three ending cards (A.3); the truck ride's captions
```

`src/resources/story/night_1.tres` … `night_3.tres`, `endless.tres` (the old `night_4` / `night_5` are gone with the 5-Night
campaign, 06 P39). `NightConfig` has one field, `story: StoryNight`, so `GameLoop.night_at(i)` keeps being the one place a Night comes
from. Generated Endless Nights point at `endless.tres`. **No story text carries a money amount**: the quotas live on the `NightConfig` and
are recalibrated (02 §3.4), the blackboard shows them; `story_data_probe` rejects a `$` followed by a digit.

Endless plays Nights 1–3 with the same story text and has no Buyout, so the finale's intro and Moe's call are worded to hold in both modes
(Moe *swears* the door opens; Gus says he never has). The finale's `ending_cards` and its own cutscene are the Campaign's alone.

`story_seen` (the Nights whose intro this player has already watched) is **per player**, so it lives in the player's own
`user://profile.json` (the `save_skins` pattern), never in `SaveProfile`: the host's checkpoint blob overwrites every peer's copy. The
same goes for Gus's said-story set (§3.3), which is per peer because Gus is cosmetic per peer (P24); it is keyed to the campaign so it
resets on a new campaign and survives a Resume. `cutscenes_seen` (§3.8) is per player and global (not per campaign).

## 3. Rules

### 3.1 Night intro cards
- At `NIGHT_START`, before Intermission, each peer shows its own intro cards: full-screen text over the dimmed bar, one tap per card,
  with a **Skip** button. On a fresh session Night 1's cards follow the intro cutscene (§3.8.1).
- The first time a player reaches a given Night, they see its cards. After that the cards are skippable with a single tap and are
  auto-skipped on Resume.
- Online, the cards are **local**: each peer pages at its own speed and Intermission starts underneath. Nobody can miss the Round: GO LIVE
  (P20) needs every connected player's press, and a player can't press it while the cards are open. A slow reader holds the start the same
  way an open bartender menu already does; four short cards are a few seconds.
- On Resume the cards of a Night this player has already seen do not open. A mid-Night resume never opens them.
- At most 4 cards per Night, each at most 140 characters. They are read on a phone between turns.

### 3.2 The phone
- During each Night's first Intermission, the wall phone rings until someone answers. It is an `Interactable` behind the counter,
  prompt "Answer the phone".
- Answering puts Moe **on speaker**. Every player sees the call as subtitles (a speech bubble above the phone), with lower, slower voice
  blips than Gus's: P24's blips at ×0.6 pitch and ×1.4 syllable length. Gus stays quiet while the call plays.
- Answering is optional. If nobody does, it stops ringing when the Round goes live, and Gus covers for it with one line from the
  `phone_ignored` pool (§4.3).
- Once answered, the phone stays quiet until the next Night. Each player's profile records the Nights whose call they heard
  (`story_called`, campaign-keyed like `story_seen`), so resuming a Night-start checkpoint after answering does not ring it again.

### 3.3 Gus
- `gus_lines` from Night N **join** his existing pools from Night N onward (P24 keeps the pep / special / pitch / reaction pools).
- While unsaid story lines remain, each ambient roll picks the story pool with probability `0.35 [tune]` (a share of rolls, not a raw
  weight next to the others). Each line is said at most once per campaign, so the story drips out instead of looping.
- His tone shifts by Night: jokes at Night 1, nervous at Night 2 (the floor), honest at Night 3. The finale (Night 3, Campaign only) is the
  only one where he drops the sarcasm (A.1): his negative reactions, sales pitches, specials of the day and cash jokes are muted that
  Night; he keeps his pep talks and his story lines. (`GameLoop.is_final_night()`: Endless has no final Night, so Gus keeps his sarcasm
  there.)

### 3.4 Hazards as Moe's people
- Every `Event` gains one flavor line, `story_line: String`, shown under its name on the vote card and on the blackboard.
- Mechanics are untouched; only the explanation changes.

| Event | story_line |
|---|---|
| Bouncer | "The Rope sent a 'doorman'. He doesn't let balls out." |
| Lights Out | "Someone forgot to pay the electric. Someone was told to forget." |
| Tilted Table | "One leg of the table got shorter overnight. Funny, that." |
| Crowd Roar | "Moe bought a few hundred viewers. They're loud and they're not yours." |
| Moving Pockets | "The Rope 'fixed' the pockets. Now the pockets move." |
| Glass Cushions | "New cushions, courtesy of Moe. Mind the bounce." |
| Ball Swap Chaos | "Somebody's been rearranging the rack. Nobody saw who." |
| Pocket Jackpot | "Moe likes a show. One pocket pays like a slot machine tonight." |

### 3.5 The ledger on the wall
The blackboard's footer stops saying "TONIGHT OWE $X" and becomes Moe's ledger. Its old "NEXT NIGHT" line gives its space to the hazard's
story line (§3.4): the ledger shows each Night's ask as soon as that Night starts. Text only, same data:
- Plain Nights (06 P39: Campaign Nights 1–2, and Endless Nights 1–3): `MOE WANTS $400 · PAID SO FAR $X`
- The Campaign's last Night (Night 3, mode Campaign only): `THE BUYOUT · $2,025 · LAST CALL`
- Endless Night 4+: `MOE RAISED THE RATE · $2,160`

(The amounts are the provisional 02 §3.4 numbers; the blackboard reads them from the `NightConfig`.) Cash can be negative after a scratch
fine (P16); the ledger shows it as it is (`-$25`).

### 3.6 Endings (phase screens and cutscenes)
- **Reckoning, Quota met:** the Night's `paid_line`, from Moe on the phone.
- **Quota missed (Game over):** the failure sequence (§3.8.2); its `short_line` is the caption over the black after the fall. The Game over
  PhaseScreen with its buttons is replaced by the run's stats card on black and then the main menu (F3b).
- **Campaign won (Buyout paid):** the win sequence (§3.8.3); the three `ending_cards` are the ride's captions. Until F3b wires it,
  `StoryDirector` still shows them as cards over the existing Campaign won screen.
- **Endless:** every Endless Night opens with one card from `endless.tres`.

### 3.7 The twist: Moe is in the chat
Moe is real, and he never needed a seat: he watches from the stream chat. Every Night, 15 s `[tune]` after Round 1 goes live, every peer
shows one stream-chat line from the viewer **velvet** (the Night's `chat_line`) as a toast, held until no modal is open. It costs nothing
and pays nothing. Nobody comments on it until the ending (A.3) says who velvet is.

### 3.8 Cutscenes (06 P39, adhoc-1013c D12, D13, A9–A11)

**Rules for all of them.** A cutscene is *local presentation on every peer*, started from a host phase transition the peer already sees;
nothing in it is networked or decides anything. Every one has a **Skip** button (and Esc / Back); the intro is skippable only after this
player has watched it once (`SaveManager.cutscene_seen`). Each plays on its own camera and puts the previous camera back; while it plays,
`UIRouter.blocking()` is true so the player and the touch controls take no input. The picture is a pure function of the **campaign seed**
and the time (the same crew wears the same gag, blindfold or hood on every peer), and the crew shown is the roster (1–4). Throws and falls
are scripted tweens, never ragdolls. Lights are realtime lights over the baked room, never a DirectionalLight (it would light the whole
level), and a cutscene that plays away from the room is staged far outside it (`Cutscene.STAGE_ORIGIN`).

**Waiting for each other (A9).** Every peer reports `CutscenePlayer.played(id, skipped)` when its copy ends; F3b sends that to the host
as a reliable ack. The host acts (starts Night 1's cards and Intermission, the main menu) when **every connected peer has acked or after
`CutscenePlayer.max_wait_sec(id)`**, which is the sequence's scripted length plus `ACK_MARGIN_SEC` (5 s), whichever comes first. A peer
that was in the background, or joins late, plays `play(id, {"instant": true})`: no scene, only the ack, and goes straight to the end state.
**Resume never replays the intro** (a Resume lands on a Round boundary). An open-ended cutscene (the truck) has no wait: nothing follows it
on the host.

#### 3.8.1 The intro (every fresh session, both modes)
1. **IntroVan**, 2.0 s: the back of the Rope's van at night, the crew on the two side benches, hands tied, each in a gag, a blindfold or a
   hood (seeded per seat). The van rocks and hits bumps, a dome light flickers, headlights and streetlamps sweep the faces.
2. **IntroCabin**, 3.0 s: the van brakes to a halt in a clearing; the cabin in the woods, porch light, "GUS'S CORNER POCKET est. 1979"; the
   engine dies and the headlights fade; the cabin door swings open on a warm glow. It ends there.
3. *(F3b, in `MainLevel`)* The crew is thrown through the door into the middle of the bar (scripted tweens), the door shuts behind them and
   locks (bolt sound, a beat of silence). Then Night 1's cards.

#### 3.8.2 Quota failure (both modes)
1. *(F3b)* A red alert light in the middle of the ceiling spins and floods the room red; the screen goes black; the mirror turns bloody
   (`Mirror.set_blood`); the TV is off (`Tv.set_feeds_on(false)`). After 5 s the floor opens (`Trapdoor`).
2. **FallCam**, 4.2 s: the camera drops through the floor into the **MonsterMouth** (a fleshy maw in the trapdoor's pit: lip, teeth,
   ribbed throat, tongue), the rest of the crew falling beside it; the teeth shut overhead and the screen goes black. It ends on black
   with the Night's `short_line` as a caption.
3. *(F3b)* The run's stats card on black (A11, §3.9), then the **main menu for everyone** (Solo and crew alike: the crew rehosts).

#### 3.8.3 Campaign win (Campaign only; Endless never wins)
1. *(F3b)* The light turns green, Gus celebrates (tweened arms, a hop), the vent opens and sprays green gas; the player's view blurs and
   goes black.
2. **TruckOutro**, open-ended: dawn; the crew sits dazed on crates on the bed of a flatbed truck. The truck is stationary in the frame
   while the world scrolls past (road, lane marks, trees, poles, a far ridge), the wheels turn, and the truck shakes: engine buzz, road
   bumps, roll and pitch, small lane-change manoeuvres. The `ending_cards` play as captions; then the **stats card** slides up along the
   bottom (§3.9). **Continue** → the main menu for everyone. Skip jumps to the card.

### 3.9 The run's stats card (A11, 02 §3.11)
`RunStatsCard`: at most 8 rows in a scroll list (Nights cleared, Balls potted, Best combo, Trick shots, Biggest shot, Cash earned,
Scratches with fines, Time played), the D–S+ grade big at the bottom. On the truck it is the **compact** form docked along the bottom of the
screen (a 140 px list that scrolls, a smaller grade, a **Continue** button); after the failure fall it is the full card on black.

## 4. Godot implementation sketch

### 4.1 Nodes and files
- `StoryDirector` (Node, child of `MainLevel`, `src/gameplay/story/story_director.gd`). It listens to `GameLoop.night_started`,
  `intermission_started`, `phase_changed(phase)` (`state_changed` has no argument). It opens the cards, arms the phone, and hands Gus his
  pool. It runs on every peer and owns no networked state except the phone's "answered this Night" flag. The host replays it to a peer
  that comes back: through `RoundDirector.send_full_state` once a Round exists, and on `NetManager.peers_away_changed` before Round 1
  (when `send_full_state` has nothing to send).
- `StoryCards` (UIModal, `src/ui/story_cards.gd/.tscn`): one modal in the `UIRouter` stack, at priority above PhaseScreen and below
  EventVote, `keep_on_phase = true` (the NIGHT_START → INTERMISSION phase change must not close it). Tap advances, Skip closes.
- `Phone` prop: an `Interactable` at the back bar (an exact spot that `decor_plan.gd`'s keep-clear accepts), kind `answer_phone`, a bare
  kind like `go_live`.
- Content: `src/resources/story/*.tres`. The `story_line` field goes on `src/resources/effect/event.gd` and into the 8 event `.tres` files.
- Art: two posters in `src/tools/make_posters.py` (`p_wanted_moe`, `p_corner_pocket_sign`) replace "live band" and the "open late" banner
  in their atlas cells, so no new material and no new layout.
- Cutscenes: `src/cutscene/` (§4.4), the flesh shader `src/shaders/flesh.gdshader`, the preview tool `src/tools/preview_cutscenes.gd`, the
  probe `tests/cutscene/cutscene_probe.gd`.

### 4.2 Networking
- **Cards:** local, no RPC.
- **Phone:** `request_world_interaction(answer_phone, 0, {})`. The host validates it in INTERMISSION, with `_reach`, and not already
  answered this Night. It goes out through the existing `world_interaction_applied` broadcast, and every peer plays the same call. The
  "answered" flag is replayed as the same interaction with `{replay: true}` (silent), so a resumed or rejoining client doesn't hear it
  ring again. `round_state` carries `campaign_seed` so every peer keys its story profile to the same campaign. **No new `@rpc`**, so the
  04 §5 table only gains a row in the kinds table.
- **Cutscenes:** local on every peer, no RPC in the framework. F3b adds ONE reliable ack rpc (peer → host, "my cutscene `id` ended") and the
  host's wait of `max_wait_sec(id)`; that rpc lands in 04 §5 and `rpc_table_probe` with F3b.
- **Gus:** stays cosmetic and per peer (P24), with the story pool seeded per Night.

### 4.3 Gus pools
`bartender_lines.gd` gains the `story` pool, filled from the current `StoryNight.gus_lines`, and `phone_ignored`, kept apart from `POOLS`
(those small pools are not P24's ≥15-line ambient pools). `bartender_chat.gd` gives `story` its `0.35 [tune]` share (§3.3) and keeps a
`said_story` set in the player profile (§2.3), so "once per campaign" survives a Resume.

### 4.4 The cutscene framework (`src/cutscene/`, F3a)

| file | class | what it is |
|---|---|---|
| `cutscene.gd` | `Cutscene` (Node3D) | The base. `configure(opts)`, `play()`, `step(dt)`, `skip()`, `abort()`, `finish()`; signal `finished(skipped)`. Owns its `Camera3D` (made current on `play()`, the previous one restored on end), its `CutsceneShell`, a seeded `rng`. A subclass overrides `id()`, `length_sec()` (0 = open-ended), `_build()`, `_update(time, dt)` (a pure function of `time`), `_environment()`, `_fade_at()`. `manual_clock` makes only `step()` advance it (probes, the preview tool). |
| `cutscene_shell.gd` | `CutsceneShell` (UIModal) | The UI layer, under a `CanvasLayer` at layer 100: a modal at **priority 100** (so `UIRouter.blocking()` holds all game input; `keep_on_phase`), a black fade, one caption line, the **Skip** button, a bottom dock for a card. Esc / Back = Skip. |
| `cutscene_player.gd` | `CutscenePlayer` (Node) | What `MainLevel` / `StoryDirector` call: `play(id, opts) -> bool`, `skip()`, `abort()`, `is_playing()`; signals `started(id)`, `played(id, skipped)`; statics `length_sec(id)`, `max_wait_sec(id)`, `ids()`, `parts_of(id)`. Ids: `intro` (= `intro_van` then `intro_cabin`, one chain: Skip skips both), `intro_van`, `intro_cabin`, `truck_outro`, `fall`. Frees each scene when it ends. |
| `crew_dress.gd` | `CrewDress` | Gag / blindfold / hood: `kind_for(seed, seat)`, `dress(humanoid, kind)` (small meshes on a `BoneAttachment3D` under the head bone; `humanoid.gd` is untouched), `spawn()` (seated crew: physics process off so a rocking parent is not read as walking), `tie_hands()`. |
| `cutscene_kit.gd` | `CutsceneKit` | `Soup` (vertex-coloured boxes / cylinders / cones / ellipsoids merged into ONE mesh = one draw call), materials, `night_env` / `sky_env`, light makers. |
| `intro_van.gd`, `intro_cabin.gd`, `truck_outro.gd`, `fall_cam.gd` (+ `.tscn`) | `IntroVan`, `IntroCabin`, `TruckOutro`, `FallCam` | The scenes of §3.8. |
| `monster_mouth.gd` (+ `.tscn`) | `MonsterMouth` | The maw prop: origin = the middle of the lip, +Y up, 2.96 m across (fits a 3 m shaft), 7.5 m of throat; `close_amount` 0..1; `pose(seconds)`; `auto` (advances itself). |

**Options** (`CutscenePlayer.play(id, opts)`; a scene reads the keys it knows): `seed` (the campaign seed: who wears what), `crew_size`,
`skins` (`Array[CharacterSkin]`, seat order), `skippable` (default true; for `intro`, true only once `SaveManager.cutscene_seen(&"intro")`),
`manual`, `parent` (default the player), `instant`; `truck_outro`: `stats` (`RunStats.to_dict()`), `captions` (the ending cards), `title`;
`fall`: `mouth` (the `MonsterMouth` in the Trapdoor's pit; given one, FallCam plays IN the room, `on_stage` false, and adds no duplicate
bodies), `drop_height` (metres from the camera's start down to the lip), `caption`, `fallers`.

**What F3b wires** (the seams, all in `MainLevel`):
- A `CutscenePlayer` child; HUD roots (HUD, touch controls, blackboard) get the group `cutscene_hides`, which the cutscene hides on `play()`
  and restores on end.
- The ack and wait of §3.8: `played` → reliable rpc to the host; host: all acks or `max_wait_sec(id)`.
- After the intro: the throw and the lock (scripted tweens), then Night 1. After `fall`: the stats card on black **in the `played` handler,
  in the same frame** (FallCam ends on black; the card must be up before the next rendered frame). After `truck_outro`: the main menu.
- `StoryDirector` stops showing `ending_cards` over the Campaign won screen once the truck plays them as captions.
- The room-side beats, which need the world lane's `Vent`, `Trapdoor` (its `Pit` anchor holds the `MonsterMouth`), `Mirror.set_blood` and
  `Tv.set_feeds_on`.

**Cost** (07 §2). Each cutscene is a one-shot scene shown alone: IntroVan ≈ 4 realtime lights, 3 meshes + the crew (2 draws a body, plus 1 for
its dress); IntroCabin ≈ 5 lights, ~12 meshes (trees, cabin, porch, van are one Soup each), 1 MultiMesh of stars; TruckOutro ≈ 2 lights,
4 scenery chunks (1 draw each), the truck (1 + 3 wheels), the crew; FallCam / MonsterMouth 4 draws (lip, throat, tongue, teeth MultiMesh), 2
lights. No shadows, no particles, no new textures beyond the existing CC0 `metal` and `floor` detail maps (the van interior and the
porch), no DirectionalLight, ≤ 8 lights per mesh. `preview_cutscenes.gd` prints draw calls, triangles and texture memory per frame; the
phone is unmeasured.

## 5. Interfaces to other modules

| from | to | what |
|---|---|---|
| `GameLoop` | `StoryDirector` | `night_started(index, quota)`, `intermission_started`, `state_changed(phase)`, `night_at(i).story` |
| `StoryDirector` | `UIRouter` | opens `StoryCards` (a `UIModal`) |
| `StoryDirector` | `BartenderChat` | `set_story_pool(lines)`, `say_from(&"phone_ignored")` |
| `WorldInteractions` | every peer | `answer_phone` through `world_interaction_applied` (04 kinds table) |
| `EconomyManager` | `PhaseScreen` | `quota_evaluated(paid, demand, is_game_over)` picks `paid_line` / `short_line` |
| `Blackboard` | `GameLoop` / `EconomyManager` | footer text per §3.5 |
| `EventVote` / `Blackboard` | `Event.story_line` | flavor under the name |
| `MainLevel` (F3b) | `CutscenePlayer` | `play(id, opts)`, `played(id, skipped)`, `max_wait_sec(id)` |
| `Cutscene` | `UIRouter` | its `CutsceneShell` is a `ui_modal` at priority 100: `UIRouter.blocking()` is true while one plays |
| `Cutscene` | HUD roots | group `cutscene_hides` hidden while it plays |
| `TruckOutro` | `RunStatsCard` | `show_stats(stats, title, true, "Continue", true)`; its `closed` ends the ride |
| `FallCam` | `MonsterMouth` / `Trapdoor` | `mouth.pose(t)`, `mouth.close_amount`; the mouth sits in the Pit anchor |
| `SaveManager` | `CutscenePlayer` | `cutscene_seen(id)` / `mark_cutscene_seen(id)`: the intro's first-watch rule |

## 6. Decisions

**06 P29 (2026-10-11 — Cleanse delegated all four):**
1. **The twist: Moe is real, and he was in the stream chat every Night** (§3.7, A.3). Not "Gus was Moe": Moe phones the bar while Gus
   stands behind the counter, and the finale only works if Gus's honesty is real.
2. **The story never touches the rules.** Text, posters, the phone and (P39) cutscenes only. The favor branch stays in Later.
3. **Moe's voice is P24's blips, lower and slower** (×0.6 pitch, ×1.4 length). No recorded audio.
4. **Cards stay local; GO LIVE is the wait.** Nobody can miss the Round start, because every connected player must press GO LIVE, and an
   open card holds that player's press (§3.1). GO LIVE itself is unchanged.

**06 P39 / adhoc-1013c (2026-10-13 — Cleanse's rulings, alpha's details):**
5. **The abduction frame replaces "lost a bet"** (D12): the Rope takes the crew, a van, a cabin hiding Gus's bar, a locked door; Gus, Moe,
   the Rope and velvet stay; 5 Nights compress to 3 (Night 3 is the finale with the ending cards).
6. **Cutscenes exist** (overrides P29's "no cutscene system"), as local presentation on every peer (D13): framework in §4.4, Skip on all,
   the intro skippable after the first watch, failure ends in the main menu for everyone.
7. **Failure = the thing under the floor; win = gassed and trucked out** (U17). The failure's stats card is on black after the fall, in
   both modes (A11); the truck carries the win's.
8. **No money in the story text**: numbers are on the blackboard, so a recalibration never leaves a card lying.

## 7. MVP cut vs later

**Built:**
- `StoryNight` resources (3 Nights + Endless) with the Appendix A text; `StoryCards`; the phone; Gus's story pool and `phone_ignored`; the
  Event `story_line`; the blackboard ledger; the two posters; velvet's chat line each Night.
- F3a: the cutscene framework, `IntroVan`, `IntroCabin`, `TruckOutro`, `MonsterMouth` + `FallCam`, the preview tool and probe.
- Probes: every campaign Night has a StoryNight inside the limits and no money amounts. Cards open once and skip. The phone rings, can be
  answered once, and survives a resume (pair probe). No story line repeats inside a campaign. Every cutscene starts, owns the current
  camera, blocks input, ends on Skip and restores the camera; the dress is fixed by the seed; the player chains the intro and acks.

**F3b (needs the world lane's Vent / Trapdoor / Mirror.set_blood / Tv.set_feeds_on):** the throw and lock, the red alert, the bloody
mirror, the floor opening, Gus's celebration and the gas, the ack rpc and the wait, the stats card on black, the main-menu routing.

**Later:**
- Recorded voice.
- Moe's silhouette in the doorway on the finale.
- Story-themed skins, e.g. "The Rope" character skin and a bar skin with "Moe's office" lighting.
- An intro card that uses the crew's own names.
- The favor branch (a drink that buys a Night's mercy).

## Appendix A — Script

Every chat line below is shown as `velvet: <text>`. No amount appears in any text (§2.3): "the number" is on the blackboard.

### A.1 Night by Night

**Night 1 — "The Van"**
- Intro cards:
  1. "The Rope took you. A van, a hood, a long road. Then a cabin in the woods, a pool bar inside, and a door that locks from outside."
  2. "Gus's Corner Pocket. One table, one camera, no windows. Gus says the front door hasn't opened since 1979."
  3. "Velvet Moe runs a stream from this room. You are tonight's show. Make the house's quota on camera, or the house keeps you."
  4. "Tonight's number is on the blackboard. Gus says it's a warm-up. Gus is lying."
- Call: "You're awake. Good. You don't know my voice yet, so let me be clear." · "The number's on the blackboard. Tonight. On stream.
  The house keeps the ones who miss." · "Gus? Pour them something cheap. They're not leaving yet."
- Gus: "First Night! I love a first Night. Everybody's so loud." · "Moe's a reasonable man. He reasons with a crowbar, but he
  reasons." · "Don't look at the phone. It can tell." · "The bar is older than the cabin. Don't ask me how that works."
- Paid: "Huh. You paid. That's the most interesting thing that's happened in this room in years."
- Short: "You missed by a little. The floor doesn't care how little."
- Chat: "first rack's always the loudest. enjoy it"

**Night 2 — "Interest"**
- Intro cards:
  1. "Night two. The door is still bolted. The stream is up, and the chat already knows your names."
  2. "Moe raised the number. 'Interest', he calls it. Gus calls it Tuesday. Gus no longer knows what day it is."
- Call: "People are watching. Good. Watching is the whole point." · "The number went up. Interest. And tell Gus I noticed the
  new cushions."
- Gus: "New cushions? I didn't buy new cushions." · "The Rope came by this afternoon. Ordered water. Tipped in threats." · "That floor by
  the table? Don't stand on it. It's fine. Just don't stand on it." · "That wanted poster? I didn't scratch the face out. I found it
  like that."
- Paid: "You paid again. You're starting to look like an investment."
- Short: "Interest keeps going after you stop. So does the floor."
- Chat: "nice cushions"

**Night 3 — "The Buyout"** (the finale in the Campaign; a plain Night in Endless, so nothing below names the Buyout's amount or promises
the door)
- Intro cards:
  1. "The Rope is in the room tonight. They don't play. They 'help'. The table leans and the lights flicker."
  2. "Tonight is the big one. Moe swears that if you pay on camera, the door opens. Gus says Moe has never opened a door."
  3. "Gus isn't joking tonight. That's how you know it's real."
- Call: "My associates will be in the room tonight. Don't thank them." · "Pay it all, on camera, and you walk. My word is on the
  record." · "Gus. You know what tonight means for you, too."
- Gus (no sarcasm, the only Night): "Forty years of crews in this room. You're the first I'd bet on." · "If this goes wrong, keep off the
  floor by the table. Please." · "The pour's on the house tonight. Don't tell Moe. Actually, tell him." · "Whatever he says on that
  phone, you don't owe him your nerve."
- Paid (Endless only): "Good. The city saw that. The city is learning."
- Short: "So close. Gus, open the floor."
- Chat: "last call"

### A.2 Ignored phone (`phone_ignored`)
- "That was for me. Probably. Let's say it was for me."
- "If anyone asks, the phone's broken. The phone is not broken."
- "He'll call back. He always calls back."

### A.3 The ending (Buyout paid): the truck's captions
1. "The Buyout clears live, in front of more viewers than this room has ever had. Gus raises a glass. Then the vent opens."
2. "You wake on a flatbed, at sunrise. The radio: 'Paid in full. The city saw. You're free.' A pause. 'Gus stays.'"
3. "One last line in the chat. velvet: 'good show. same table next week?' You never saw the name until now. He never missed a shot."

Endless (`endless.tres`), one card per Night past the third: "Somebody bought Gus's debt. The rate went up. The door stays locked. The
stream goes on." Chat: "same table. new rate".

### A.4 Cutscene captions
The intro and the failure carry no captions of their own: the cards after the intro tell what happened, and the failure's one line is the
Night's `short_line`, over the black after the fall. The truck's are A.3.
