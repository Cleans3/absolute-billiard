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
