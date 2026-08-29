# Absolute Billiard — design plan contract (frozen 2026-08-29)

Engine: Godot 4.7 (project.godot present, mobile renderer, near-empty: src/{core,gameplay,levels,ui,...}).
Scope of THIS pass: systems design only. **Player-related design (character, controller, animation, cosmetics, input) is DEFERRED — do not design it.** Reference it only as "Player" black box.

## Pitch (authoritative)
- Multiplayer friends-only: open lobby + invite friends, or singleplayer. Max 4 players. No random matchmaking.
- Setting: players spawn in a bar with one billiard table.
- Real pool physics, NO standard pool rules (no 8-ball/9-ball).
- Loop: crew owes a gangster money -> quota ($) per period -> earn by playing pool on a livestreamed table (cameras = income source).
- Balls: many colors/types, each with own reward. Potting = default score; trick shots = bonus; some balls worth more. Round start: balls dropped at random positions.
- Events make shooting harder for more points. Bar drinks give temporary effects.

## Shared vocabulary (use EXACTLY these names)
- `Ball` — physics body; has `BallType`
- `BallType` — resource: id, color, base_value, behaviour tags
- `Shot` — one cue strike until all balls rest
- `Turn` — one player's Shot
- `Round` — balls dropped -> played until table cleared or timer/shots exhausted
- `Night` — quota period; N rounds; ends with debt payment to gangster
- `Quota` — $ owed by end of Night
- `Cash` — crew-shared currency
- `Stream` — livestream state; `Viewers` scalar drives $ multiplier
- `Camera` — placeable/upgradable stream source
- `Drink` — consumable from bar; applies `Effect`
- `Effect` — timed modifier on player/table/ball (single schema shared by Drink and Event)
- `Event` — round-level hazard/modifier; raises reward multiplier
- `TrickShot` — detected shot pattern with bonus

## Doc template (every module doc)
1. Purpose (2 lines) 2. Concepts & data model (resources, fields, types) 3. Rules/formulas (explicit numbers, tunable table) 4. Godot implementation sketch (nodes, autoloads, signals, file paths under src/) 5. Interfaces to other modules (signals/methods, by vocabulary name) 6. Open questions 7. MVP cut vs later
Markdown, headings, tables. Numbers concrete (placeholder-tuned is fine, mark `[tune]`).

## Module ownership (one doc each, no cross-writes)
- 01-physics-table-balls.md — physics model, cue/aim, table, BallType taxonomy, scoring per ball, TrickShot detection, random drop
- 02-economy-loop.md — Night/Round/Quota structure, gangster debt curve, Stream/Viewers/Camera income model, fail/win states, progression
- 03-bar-drinks-events.md — Drink catalog + Effect schema, Event catalog (round hazards), difficulty/reward multipliers
- 04-architecture-netcode.md — Godot 4.7 project layout, autoloads, scene tree, module boundaries, friend lobby/invite (Steam? ENet?), host-authoritative physics sync, save data
- 05-index.md — alpha: integration, cross-module signal map, review checklist
