# 09 — Story: "The Last Table"

## 1. Purpose

This doc gives the debt loop (02) a reason and a face. The crew owes Velvet Moe, Gus owns the bar
and owes him too, and the stream is how Moe wants to be paid. The story is told through what the
game already has: the bartender's lines, the walls, the blackboard, the phase screens. No cutscene
system and no rule changes.

## 2. Concepts & data model

### 2.1 The cast

| who | what they are | where the player meets them |
|---|---|---|
| **The crew** | 1–4 amateur players who lost a bet they should never have taken. They are never named; players bring their own names. | everywhere |
| **Gus** | The bartender and owner of *Gus's Corner Pocket*, the bar the game takes place in. He owes Moe more than the crew does. He lets amateurs stream on his only table because a crew paying Moe in public keeps Moe off *his* back. His sarcasm is fear in a bow tie. | behind the counter (P24 body, `bartender_*`) |
| **Velvet Moe** | A loan shark who works out of pool halls. He is never seen, only heard: on the phone, in the ledger, in what his people leave behind. He takes his money **on stream**, because a debt paid where the whole city can watch teaches the city something. | the phone behind the bar, the wanted poster, the Reckoning |
| **The Rope** | Moe's collectors. They don't play, they "help". They are the in-world source of the hazards. | Event flavor lines (§3.4) |

### 2.2 The place

*Gus's Corner Pocket*, established 1979: one table, one stream and one bad decision a night. It's the
room we already have (`BarRoom`), with the story in its details:

- A **wanted-style poster of Moe** that someone has defaced to read "VELVET MOE — DO NOT ASK".
  It is the only portrait of him, and the face is scratched out.
- A **"Gus's Corner Pocket — est. 1979" sign** above the back bar.
- A **wall phone** behind the counter. It rings once per Night (§3.2).
- The **blackboard's debt line** reads as Moe's demand (§3.5).

### 2.3 Data

One resource per campaign Night. Endless Nights reuse one shared resource.

```
StoryNight (Resource)          src/resources/story/story_night.gd
  night: int                   # 1..5; 0 = the Endless resource
  intro_cards: Array[String]   # shown at NIGHT_START, before Intermission; [] = none
  call: Array[String]          # Moe on the phone, one subtitle per line; [] = no call this Night
  gus_lines: Array[String]     # extra ambient lines for Gus, unlocked from this Night on
  paid_line: String            # Reckoning line when the Quota is met
  short_line: String           # the Game over line for this Night (Moe collects)
```

`src/resources/story/night_1.tres` … `night_5.tres`, `endless.tres`. `NightConfig` gains one
field, `story: StoryNight`, so `GameLoop.night_at(i)` keeps being the one place a Night comes from.
Generated Endless Nights point at `endless.tres`.

`SaveProfile` gains `story_seen: PackedInt32Array`, the Nights whose intro this player has already
watched. It is per player, not per campaign, so a replay can skip what you already know (§3.1).

## 3. Rules

### 3.1 Night intro cards
- At `NIGHT_START`, before Intermission, each peer shows its own intro cards: full-screen text over
  the dimmed bar, one tap per card, with a **Skip** button.
- The first time a player reaches a given Night, they see its cards. After that the cards are
  skippable with a single tap and are auto-skipped on Resume.
- Online, the cards are **local**: nobody waits on anyone. Intermission starts underneath, and the
  GO LIVE pedestal already covers who is ready.
- At most 4 cards per Night, each at most 140 characters. They are read on a phone between turns.

### 3.2 The phone
- During each Night's first Intermission, the wall phone rings until someone answers. It is an
  `Interactable` behind the counter, prompt "Answer the phone".
- Answering puts Moe **on speaker**. Every player sees the call as subtitles (a speech bubble above
  the phone), with lower, slower voice blips than Gus's (P24's blips at another pitch).
- Answering is optional. If nobody does, it stops ringing when the Round goes live, and Gus covers
  for it with one line from the `phone_ignored` pool (§4.3).
- Once answered, the phone stays quiet until the next Night.

### 3.3 Gus
- `gus_lines` from Night N **join** his existing pools from Night N onward (P24 keeps the
  pep / special / pitch / reaction pools).
- Story lines are drawn at weight `0.35 [tune]` against the other ambient pools. Each one is said at
  most once per campaign, so the story drips out instead of looping.
- His tone shifts by Night: jokes at Night 1, nervous at 3, honest at 5. Night 5 is the only one
  where he drops the sarcasm (A.1).

### 3.4 Hazards as Moe's people
- Every `Event` gains one flavor line, `story_line: String`, shown under its name on the vote card
  and on the blackboard.
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
The blackboard's footer stops saying "TONIGHT OWE $600" and becomes Moe's ledger. Text only, same
data:
- Nights 1–4: `MOE WANTS $600 · PAID SO FAR $X`
- Night 5: `THE BUYOUT · $4,500 · LAST CALL`
- Endless: `MOE RAISED THE RATE · $4,800`

### 3.6 Endings (phase screens, text only)
- **Reckoning, Quota met:** the Night's `paid_line`, from Moe on the phone.
- **Game over (Quota missed):** the Night's `short_line`. Same screen and buttons as today.
- **Campaign won (Buyout paid):** three cards (A.3), then the existing Endless / Menu buttons.
- **Endless:** every Endless Night opens with one card from `endless.tres`.

## 4. Godot implementation sketch

### 4.1 Nodes and files
- `StoryDirector` (Node, child of `MainLevel`, `src/gameplay/story/story_director.gd`). It listens
  to `GameLoop.night_started`, `intermission_started`, `state_changed`. It opens the cards, arms the
  phone, and hands Gus his pool. It runs on every peer and owns no networked state.
- `StoryCards` (UIModal, `src/ui/story_cards.gd/.tscn`): one modal in the `UIRouter` stack, at
  priority above PhaseScreen. Tap advances, Skip closes.
- `Phone` prop: an `Interactable` at the back bar (an exact spot that `decor_plan.gd`'s keep-clear
  accepts), kind `answer_phone`, a bare kind like `go_live`.
- Content: `src/resources/story/*.tres`. The `story_line` field goes on `src/resources/effect/event.gd`
  and into the 8 event `.tres` files.
- Art: two new posters in `src/tools/make_posters.py` (`p_wanted_moe`, `p_corner_pocket_sign`), in
  the same atlas, so no new material.

### 4.2 Networking
- **Cards:** local, no RPC.
- **Phone:** `request_world_interaction(answer_phone, 0, {})`. The host validates it in
  INTERMISSION, with `_reach`, and not already answered this Night. It goes out through the
  existing `world_interaction_applied` broadcast, and every peer plays the same call. The
  "answered" flag rides GameLoop's `full_state`, so a resumed client doesn't hear it ring again.
  **No new `@rpc`**, so the 04 §5 table only gains a row in the kinds table.
- **Gus:** stays cosmetic and per peer (P24), with the story pool seeded per Night.

### 4.3 Gus pools
`bartender_lines.gd` gains the `story` pool, filled from the current `StoryNight.gus_lines`, and
`phone_ignored`. `bartender_chat.gd` adds `story` to the ambient draw at `0.35 [tune]` and keeps a
`said_story` set in the campaign checkpoint, so "once per campaign" survives a Resume.

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

## 6. Open questions (Cleanse decides)

1. **The twist.** The draft ending says Gus *was* Velvet Moe all along: the bar is his collection
   office, and the "owner in debt" act is how he keeps crews paying. The alternative: Moe is real,
   and the twist is that he was in the stream chat every night. Pick one before Appendix A is written in
   full.
2. **Should the story ever touch the rules?** The draft is presentation only. One option: on Night 4,
   if the crew is ahead, Gus quietly offers a "favor" drink, and accepting it unlocks the true
   ending. That would be a real branch, with economy and design work.
3. **Moe's voice.** Lower blips are the default. A short real voice line (one recorded "Evening.")
   would be the first non-generated audio file.
4. **Skip policy online.** Cards are local, so a slow reader never holds anyone up, but they might
   miss the first Round's start. The alternative is that Round 1 of a Night waits until every peer
   has closed its cards. Only that would change GO LIVE.

## 7. MVP cut vs later

**MVP (one slice):**
- `StoryNight` resources with the Appendix A text.
- `StoryCards` at NIGHT_START.
- The phone with the speaker-call subtitle.
- Gus's story pool and `phone_ignored`.
- The Event `story_line` field.
- The blackboard ledger wording.
- The two posters.
- The Reckoning, Game over and Campaign won lines.
- Probes: every campaign Night has a StoryNight. Cards open once and skip. The phone rings, can be
  answered once, and survives a resume (pair probe). No story line repeats inside a campaign.

**Later:**
- The Night 4 favor branch.
- Recorded voice.
- Moe's silhouette in the doorway on Night 5.
- Story-themed skins, e.g. "The Rope" character skin and a bar skin with "Moe's office" lighting.
- An intro card that uses the crew's own names.

## Appendix A — Script, first pass

### A.1 Night by Night

**Night 1 — "The Bet"** (Quota $600)
- Intro cards:
  1. "You bet on yourselves. Against Velvet Moe. In his own pool hall."
  2. "You lost. Moe doesn't want your money. He wants it *earned*. On stream. Where people can watch."
  3. "Gus's Corner Pocket. One table. One camera. Gus says it's the only bar in town that would have you."
  4. "Moe wants $600 by closing. Gus says it's a warm-up. Gus is lying."
- Call: "Evening. You don't know my voice yet, so let me be clear." · "Six hundred. Tonight.
  Smile for the camera." · "Gus? Pour them something cheap. They're paying."
- Gus: "First Night! I love a first Night. Everybody's so hopeful." · "Moe's a reasonable man.
  He reasons with a crowbar, but he reasons." · "Don't look at the phone. It can tell."
  · "My first Night I owed him forty dollars. That was 1979."
- Paid: "Huh. You paid. That's the most interesting thing that's happened in this bar in years."
- Short: "Six hundred dollars. You couldn't find six hundred dollars. Gus, lock the door."

**Night 2 — "Interest"** (Quota $900)
- Intro cards:
  1. "Moe kept his word. The stream is up, and the chat already knows your names."
  2. "Nine hundred tonight. 'Interest', Moe calls it. Gus calls it Tuesday."
- Call: "People are watching. Good. Watching is the whole point." · "Nine hundred. And tell Gus I
  noticed the new cushions."
- Gus: "New cushions? I didn't buy new cushions." · "The Rope came by this afternoon. Ordered
  water. Tipped in threats." · "Every time you scratch, somewhere a loan shark smiles."
  · "That wanted poster? I didn't scratch the face out. I found it like that."
- Paid: "Nine hundred. You're starting to look like an investment."
- Short: "Interest is a funny thing. It keeps going after you stop."

**Night 3 — "The Rope"** (Quota $1,350)
- Intro cards:
  1. "Moe's collectors came in tonight. They don't play. They 'help'."
  2. "The table feels different. The lights feel different. Gus doesn't feel anything. Gus has had
     three drinks."
- Call: "My associates will be in the room tonight. Don't thank them." · "Thirteen fifty. The
  viewers like it when it's close."
- Gus: "If the table leans, lean with it. That's life advice." · "Gus's rule: never ask who
  sharpened the pockets." · "I used to have a pool cue signed by a champion. Moe has it now.
  He uses it to point." · "You're getting better. That's worse for me, somehow."
- Paid: "Good. The city saw that. The city is learning."
- Short: "Three Nights. I'll admit I'd started to like the show."

**Night 4 — "The Ledger"** (Quota $2,000)
- Intro cards:
  1. "Gus finally showed you his ledger. Your debt is on page one. His goes on for forty pages."
  2. "'If you pay him off,' Gus says, 'maybe he forgets about me.' He doesn't sound like he
     believes it."
- Call: "Gus has been talking. Gus always talks on the fourth Night." · "Two thousand. And
  then we discuss a final number."
- Gus: "You saw the ledger. Don't look at me like that. I'm a businessman." · "Forty pages.
  Some of them are just drawings of a crowbar." · "If you win this, I'm putting your photo
  above the bar. Next to the wanted poster. For balance." · "He calls on the fourth Night. He
  always calls on the fourth Night."
- Paid: "Then it's settled. Tomorrow, the Buyout. Everything. Bring a crowd."
- Short: "So close. People always are, on the fourth Night."

**Night 5 — "Last Call"** (Buyout $4,500)
- Intro cards:
  1. "The Buyout. Four and a half thousand, and you're free. Moe promised. On air."
  2. "Gus isn't joking tonight. That's how you know it's real."
  3. "Whatever happens: this is the best stream this bar has ever had."
- Call: "Last call. Pay it all, on camera, and you walk. My word is on the record." · "Gus. You
  know what tonight means for you too."
- Gus (no sarcasm, the only Night): "I've watched forty years of crews at that table. You're the
  first one I'd bet on." · "If this goes wrong, the back door sticks. Kick it twice."
  · "Pour's on the house tonight. Don't tell Moe. Actually, tell him." · "Whatever he says on that
  phone, you don't owe him your nerve."
- Short: "Gus. Close the bar. The show's over."

### A.2 Ignored phone (`phone_ignored`)
- "That was for me. Probably. Let's say it was for me."
- "If anyone asks, the phone's broken. The phone is not broken."
- "He'll call back. He always calls back."

### A.3 The ending (Buyout paid)
1. "The Buyout clears live, in front of more viewers than this bar has ever had."
2. "The phone rings one last time. Moe: 'Paid in full. The city saw. You're free.' A pause.
   'Gus, my office. Tomorrow.'"
3. "Gus pours you a drink and doesn't charge for it. Then he takes the wanted poster down, turns it
   over, and you see the face underneath for the first time. It's an old photo of Gus. Signed:
   'Velvet'."

Endless (`endless.tres`), one card per Night: "Somebody bought Gus's debt. The rate went up. The
stream goes on."
