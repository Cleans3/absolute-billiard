#!/usr/bin/env bash
# Bakes BarRoom's LightmapGI (04 §2.2). Needs a GPU window (DISPLAY) — never --headless.
# Re-run src/tools/build_bar_room.gd first if the greybox changed (it resets the bake).
# Temporarily enables src/tools/bake_plugin in project.godot, restores it on exit.
set -euo pipefail
cd "$(dirname "$0")/../.."
cp project.godot /tmp/project.godot.bake-bak
before=$(git diff --name-only)
trap 'cp /tmp/project.godot.bake-bak project.godot; for f in $(git diff --name-only); do case $f in src/gameplay/bar_room/BarRoom.*) continue;; esac; grep -qxF "$f" <<<"$before" || git checkout -- "$f"; done' EXIT  # editor re-saves .tres uids: undo those (never the bake's own outputs)
sed -i 's|^enabled=PackedStringArray(\(.*\))|enabled=PackedStringArray(\1, "res://src/tools/bake_plugin/plugin.cfg")|' project.godot
godot --path . --editor -- bake-bar-room 2>&1 | tee /tmp/bake.log | grep -E "BAKE|rror|Bake" || true
grep -q "BAKE DONE light_data=(res" /tmp/bake.log && ls src/gameplay/bar_room/*.lmbake
