#!/usr/bin/env bash
# Builds the Android APK (debug by default) with the Godot export templates.
#
# Requirements: Godot 4.5.1 (GODOT env var), its export templates installed,
# Android SDK (build-tools 35, platform 35), JDK 17+.
# Usage:
#   GODOT=/path/to/godot ANDROID_SDK=/path/to/sdk tools/build_apk.sh [debug|release|pack]
# release: needs KEYSTORE, KEYSTORE_USER, KEYSTORE_PASS (never commit them).
# pack:    exports only build/game.pck - the game-code update published to the
#          update server (no APK rebuild needed for players).
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-debug}"
GODOT="${GODOT:-godot}"
ANDROID_SDK="${ANDROID_SDK:-${ANDROID_HOME:-}}"
JAVA_HOME="${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")}"
[[ -n "$ANDROID_SDK" ]] || { echo "Set ANDROID_SDK"; exit 1; }

CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/godot"
mkdir -p "$CFG_DIR" build
SETTINGS="$CFG_DIR/editor_settings-4.5.tres"
if [[ ! -f "$SETTINGS" ]]; then
  printf '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n' > "$SETTINGS"
fi
set_setting() { # key value
  sed -i "\|^$1 = |d" "$SETTINGS"
  echo "$1 = \"$2\"" >> "$SETTINGS"
}
set_setting export/android/android_sdk_path "$ANDROID_SDK"
set_setting export/android/java_sdk_path "$JAVA_HOME"

if [[ "$MODE" == "pack" ]]; then
  "$GODOT" --headless --import >/dev/null 2>&1 || true
  rm -f build/game.pck
  "$GODOT" --headless --export-pack "Android" build/game.pck
  [[ -f build/game.pck ]] || { echo "pck export failed"; exit 1; }
  echo "Built build/game.pck ($(du -h build/game.pck | cut -f1))"
  exit 0
elif [[ "$MODE" == "debug" ]]; then
  KS="${DEBUG_KEYSTORE:-build/debug.keystore}"
  if [[ ! -f "$KS" ]]; then
    keytool -genkeypair -keystore "$KS" -storepass android -alias androiddebugkey -keypass android \
      -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Android Debug,O=Android,C=US" >/dev/null
  fi
  set_setting export/android/debug_keystore "$(readlink -f "$KS")"
  set_setting export/android/debug_keystore_user androiddebugkey
  set_setting export/android/debug_keystore_pass android
  "$GODOT" --headless --import >/dev/null 2>&1 || true
  "$GODOT" --headless --export-debug "Android" build/ashenfall_ufa.apk
else
  : "${KEYSTORE:?KEYSTORE required}" "${KEYSTORE_USER:?}" "${KEYSTORE_PASS:?}"
  export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$KEYSTORE"
  export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$KEYSTORE_USER"
  export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$KEYSTORE_PASS"
  "$GODOT" --headless --import >/dev/null 2>&1 || true
  "$GODOT" --headless --export-release "Android" build/ashenfall_ufa-release.apk
fi
APK=$(ls -t build/*.apk | head -1)
BT=$(ls -d "$ANDROID_SDK"/build-tools/* | sort -V | tail -1)
"$BT/apksigner" verify "$APK"
"$BT/zipalign" -c -P 16 4 "$APK" && echo "16 KB page alignment: OK"
echo "Built $APK ($(du -h "$APK" | cut -f1))"
