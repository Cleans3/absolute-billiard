#!/usr/bin/env bash
# M7 (docs/plan/04 §2.3): PC-only Steam transport. Drops two GDExtensions into addons/ (gitignored, Linux+Windows
# 64-bit only) and writes steam_appid.txt (480 = Spacewar, public dev app id; no publisher key ever lives here):
#   GodotSteam GDExtension 4.22.1 (Steamworks 1.65)  codeberg.org/godotsteam/godotsteam        (MIT)
#   Steam Multiplayer Peer 0.2.5                     github.com/expressobits/steam-multiplayer-peer  (MIT)
# Both archives are pinned to a commit AND a sha256; a mismatch aborts before anything is unzipped.
# These are native binaries that Godot will load: read this script, run it yourself.
# Phone builds never see them: the Android preset excludes both addon folders.
set -euo pipefail
cd "$(dirname "$0")/../.."

GS_URL=https://codeberg.org/godotsteam/godotsteam/archive/baa0b1c2c16b822c9641f94f7d38558b21a3daf2.zip
GS_SHA=aa31d7208c651f80ef1fccf1be96a4e476c1abf0fb018dd72d9db7bc2929971d
MP_URL=https://github.com/expressobits/steam-multiplayer-peer/archive/93542884f1ce7d7d18bc6f5e2f5ec1ef77547a30.zip
MP_SHA=197a1bb07604ac8880767ce5731974346645e6d2d30dd0752f25fa845ec115df

t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
fetch() {  # python, not curl: works on boxes without curl; a UA header because some CDNs 403 python-urllib
  python3 -c 'import sys,urllib.request,shutil
r=urllib.request.Request(sys.argv[1],headers={"User-Agent":"fetch-godotsteam/1"})
shutil.copyfileobj(urllib.request.urlopen(r),open(sys.argv[2],"wb"),1<<20)' "$1" "$2"
}
verify() {  # verify <file> <sha256>
  local got; got="$(sha256sum "$1" | cut -d' ' -f1)"
  [ "$got" = "$2" ] || { echo "CHECKSUM MISMATCH for $1: got $got, want $2" >&2; exit 1; }
}

fetch "$GS_URL" "$t/gs.zip"; verify "$t/gs.zip" "$GS_SHA"
fetch "$MP_URL" "$t/mp.zip"; verify "$t/mp.zip" "$MP_SHA"
unzip -q "$t/gs.zip" -d "$t/gs"; unzip -q "$t/mp.zip" -d "$t/mp"

rm -rf addons/godotsteam addons/steam-multiplayer-peer
mkdir -p addons
cp -r "$t"/gs/*/addons/godotsteam addons/godotsteam
cp -r "$t"/mp/*/addons/steam-multiplayer-peer addons/steam-multiplayer-peer
# desktop 64-bit only
rm -rf addons/godotsteam/{androidarm64,linux32,win32,osx,editor} addons/godotsteam/godotsteam_plugin.gd* \
       addons/steam-multiplayer-peer/{macos,android,ios}
echo 480 > steam_appid.txt

godot --headless --path . --import >/dev/null 2>&1 || true
echo "GODOTSTEAM OK  (addons/godotsteam, addons/steam-multiplayer-peer, steam_appid.txt=480)"
