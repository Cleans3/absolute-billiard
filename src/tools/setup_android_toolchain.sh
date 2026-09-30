#!/usr/bin/env bash
# One-shot, idempotent Android export toolchain for Godot 4.7.1 (docs: exporting_for_android):
# OpenJDK 17, SDK cmdline-tools + platform-tools + build-tools 35.0.1 + platform 35 + NDK r28b + CMake,
# the 4.7.1 export templates, a debug keystore, and the two editor-settings paths. No sudo.
# Big payloads go to $TOOLCHAIN_DIR (default: a roomy disk) and are symlinked into place.
set -euo pipefail

GODOT_VER=4.7.1
SDK=${ANDROID_HOME:-$HOME/Android/Sdk}
JDK_DIR=${JDK_DIR:-$HOME/.local/jdk-17}
TOOLCHAIN_DIR=${TOOLCHAIN_DIR:-$HOME/.local/share/godot-toolchain}
TEMPLATES_LINK=$HOME/.local/share/godot/export_templates/${GODOT_VER}.stable
KEYSTORE=$HOME/.local/share/godot/keystores/debug.keystore
CMDLINE_ZIP=commandlinetools-linux-16111833_latest.zip
EDITOR_SETTINGS=$HOME/.config/godot/editor_settings-4.7.tres

fetch() {  # python, not curl: works on boxes without curl; a UA header because some CDNs 403 python-urllib
  python3 -c 'import sys,urllib.request,shutil
r=urllib.request.Request(sys.argv[1],headers={"User-Agent":"setup-android-toolchain/1"})
shutil.copyfileobj(urllib.request.urlopen(r),open(sys.argv[2],"wb"),1<<20)' "$1" "$2"
}

mkdir -p "$TOOLCHAIN_DIR" "$(dirname "$TEMPLATES_LINK")" "$(dirname "$KEYSTORE")"

if [ ! -x "$JDK_DIR/bin/java" ]; then
  echo "== JDK 17"
  fetch "https://api.adoptium.net/v3/binary/latest/17/ga/linux/x64/jdk/hotspot/normal/eclipse" "$TOOLCHAIN_DIR/jdk17.tar.gz"
  mkdir -p "$JDK_DIR" && tar -xzf "$TOOLCHAIN_DIR/jdk17.tar.gz" -C "$JDK_DIR" --strip-components=1
  rm "$TOOLCHAIN_DIR/jdk17.tar.gz"
fi
export JAVA_HOME=$JDK_DIR PATH=$JDK_DIR/bin:$PATH

if [ ! -x "$SDK/cmdline-tools/latest/bin/sdkmanager" ]; then
  echo "== SDK cmdline-tools"
  fetch "https://dl.google.com/android/repository/$CMDLINE_ZIP" "$TOOLCHAIN_DIR/$CMDLINE_ZIP"
  rm -rf "$SDK/cmdline-tools/latest" && mkdir -p "$SDK/cmdline-tools"
  (cd "$SDK/cmdline-tools" && unzip -q "$TOOLCHAIN_DIR/$CMDLINE_ZIP" && mv cmdline-tools latest)
  rm "$TOOLCHAIN_DIR/$CMDLINE_ZIP"
fi

echo "== SDK packages"
# `< <(yes)`, not `yes |`: under pipefail the SIGPIPE'd `yes` would fail the step
"$SDK/cmdline-tools/latest/bin/sdkmanager" --sdk_root="$SDK" \
  "platform-tools" "build-tools;35.0.1" "platforms;android-35" "cmake;3.10.2.4988404" "ndk;28.1.13356709" \
  < <(yes) >/dev/null

if [ ! -f "$TEMPLATES_LINK/version.txt" ]; then
  echo "== export templates $GODOT_VER (1.3 GB)"
  tpz=$TOOLCHAIN_DIR/Godot_v${GODOT_VER}-stable_export_templates.tpz
  [ -f "$tpz" ] || fetch "https://github.com/godotengine/godot/releases/download/${GODOT_VER}-stable/Godot_v${GODOT_VER}-stable_export_templates.tpz" "$tpz"
  rm -rf "$TOOLCHAIN_DIR/templates" && mkdir -p "$TOOLCHAIN_DIR/templates"
  unzip -q "$tpz" -d "$TOOLCHAIN_DIR/templates"
  rm -rf "$TEMPLATES_LINK" && ln -s "$TOOLCHAIN_DIR/templates/templates" "$TEMPLATES_LINK"
  rm "$tpz"
fi

if [ ! -f "$KEYSTORE" ]; then
  echo "== debug keystore"
  keytool -keyalg RSA -genkeypair -alias androiddebugkey -keypass android -keystore "$KEYSTORE" \
    -storepass android -dname "CN=Android Debug,O=Android,C=US" -validity 9999 -deststoretype pkcs12
fi

echo "== editor settings"
if [ -f "$EDITOR_SETTINGS" ]; then
  sed -i -E "s|^export/android/java_sdk_path = .*|export/android/java_sdk_path = \"$JDK_DIR\"|; s|^export/android/android_sdk_path = .*|export/android/android_sdk_path = \"$SDK\"|" "$EDITOR_SETTINGS"
  grep -q '^export/android/java_sdk_path' "$EDITOR_SETTINGS" || echo "export/android/java_sdk_path = \"$JDK_DIR\"" >> "$EDITOR_SETTINGS"
fi
echo "TOOLCHAIN OK  java=$("$JDK_DIR/bin/java" -version 2>&1 | head -1)  templates=$(cat "$TEMPLATES_LINK/version.txt")"
