#!/usr/bin/env bash
# End-to-end test of game-code updates without a new APK, on a desktop export
# (same Bootstrap logic as Android):
#   1. export a "base" build (stands in for the installed APK);
#   2. export an update .pck where an autoload changed and a NEW class_name was added;
#   3. package + sign it with afpkg build-code, import into the base build;
#   4. the base build must run the updated code;
#   5. a version that never reaches the menu is disabled after 2 tries and the
#      previous working pack is restored automatically.
# Requires: GODOT (4.5.1) with export templates, python3 + cryptography.
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
ROOT="$(pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
USERDATA="$TMP/userdata"  # isolated user:// of the game only (the editor keeps its templates)
ENGINE="$("$GODOT" --version | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
[[ "$ENGINE" =~ ^[0-9]+\.[0-9]+$ ]] && ENGINE="$ENGINE.0"
APK_BUILD="$(grep -oE 'config/apk_build=[0-9]+' project.godot | cut -d= -f2)"
fail() { echo "FAIL: $*"; exit 1; }

copy_project() { # dst
  mkdir -p "$1"
  tar -C "$ROOT" --exclude=.godot --exclude=build --exclude=dist --exclude=.git -cf - . | tar -C "$1" -xf -
}

echo "== keys"
openssl genrsa -out "$TMP/test_release_private.pem" 2048 2>/dev/null
openssl rsa -in "$TMP/test_release_private.pem" -pubout -out "$TMP/test_release.pem" 2>/dev/null

echo "== base build"
copy_project "$TMP/base"
cp "$TMP/test_release.pem" "$TMP/base/config/trusted_keys/test_release.pem"
"$GODOT" --path "$TMP/base" --headless --import >/dev/null 2>&1 || true
mkdir -p "$TMP/bin"
"$GODOT" --path "$TMP/base" --headless --export-debug "Linux" "$TMP/bin/game.x86_64" >/dev/null 2>&1
[[ -f "$TMP/bin/game.pck" ]] || fail "base export"
run() { XDG_DATA_HOME="$USERDATA" "$TMP/bin/game.x86_64" --headless -- "$@" 2>&1 | grep -E "AF_|\[bootstrap\]" || true; }

out="$(run af-print-versions af-mark-ok)"; echo "$out"
grep -q "code=0.1.0" <<<"$out" || fail "base should run 0.1.0"
grep -q "probe=<null>" <<<"$out" || fail "base must not have the probe"

make_update() { # version probe-value
  local dir="$TMP/upd_$1"
  copy_project "$dir"
  cp "$TMP/test_release.pem" "$dir/config/trusted_keys/test_release.pem"
  cat > "$dir/core/update_probe.gd" <<EOF
class_name AfUpdateProbe
extends RefCounted
const VALUE := "$2"
EOF
  printf '\nvar build_probe: String = AfUpdateProbe.VALUE\n' >> "$dir/core/event_bus.gd"
  "$GODOT" --path "$dir" --headless --import >/dev/null 2>&1 || true
  "$GODOT" --path "$dir" --headless --export-pack "Linux" "$TMP/game_$1.pck" >/dev/null 2>&1
  [[ -f "$TMP/game_$1.pck" ]] || fail "pck export $1"
  python3 tools/afpkg.py build-code --pck "$TMP/game_$1.pck" --version "$1" --engine "$ENGINE" \
    --min-apk-build "$APK_BUILD" --key "$TMP/test_release_private.pem" --out "$TMP/dist" >/dev/null
  echo "$TMP/dist/packages/game.core/$1/game.core-$1.zip"
}

echo "== update 0.1.5 (changed autoload + new class_name)"
zip="$(make_update 0.1.5 v2)"
out="$(run "af-import=$zip")"; echo "$out"
grep -q "AF_IMPORT ok=true" <<<"$out" || fail "import 0.1.5"
out="$(run af-print-versions af-mark-ok)"; echo "$out"
grep -q "code=0.1.5" <<<"$out" || fail "code version after update"
grep -q "probe=v2" <<<"$out" || fail "updated autoload / new class_name not running"

echo "== tampered pack is refused at boot"
cp "$USERDATA/ashenfall_ufa/content/packages/game.core/code/game.pck" "$TMP/good.pck"
printf 'x' >> "$USERDATA/ashenfall_ufa/content/packages/game.core/code/game.pck"
out="$(run af-print-versions af-mark-ok)"; echo "$out"
grep -q "code=0.1.0" <<<"$out" || fail "tampered pack must not mount"
grep -q "повреждён" <<<"$out" || fail "tamper reason"
cp "$TMP/good.pck" "$USERDATA/ashenfall_ufa/content/packages/game.core/code/game.pck"

echo "== broken update 0.1.6 never reaches the menu"
zip="$(make_update 0.1.6 v3)"
run "af-import=$zip" >/dev/null
out1="$(run af-print-versions)"; out2="$(run af-print-versions)"
grep -q "probe=v3" <<<"$out2" || fail "0.1.6 should mount on first tries"
out3="$(run af-print-versions)"; echo "$out3"
grep -q "дважды не запустилась" <<<"$out3" || fail "crash guard should disable 0.1.6"
out4="$(run af-print-versions af-mark-ok)"; echo "$out4"
grep -q "code=0.1.5" <<<"$out4" || fail "previous working pack should be restored"
grep -q "probe=v2" <<<"$out4" || fail "restored code should run"


echo "== network self-update from the update server"
rm -rf "$USERDATA"
python3 tools/afpkg.py build-code --pck "$TMP/game_0.1.5.pck" --version 0.1.7 --engine "$ENGINE" \
  --min-apk-build "$APK_BUILD" --key "$TMP/test_release_private.pem" --out "$TMP/srv" >/dev/null
AFPKG_QUIET=1 python3 tools/afpkg.py serve --out "$TMP/srv" --port 8798 --host 127.0.0.1 >/dev/null 2>&1 &
SRV=$!
sleep 1
out="$(run af-server=http://127.0.0.1:8798 af-update)"; echo "$out"
kill $SRV
grep -q "offered=0.1.7" <<<"$out" || fail "update not offered"
grep -q "installed=0.1.7" <<<"$out" || fail "update not installed"
out="$(run af-print-versions af-mark-ok)"; echo "$out"
grep -q "code=0.1.7" <<<"$out" || fail "downloaded code not running after restart"
grep -q "probe=v2" <<<"$out" || fail "downloaded code probe"
echo "NETWORK UPDATE PASSED"
echo "ALL CODE-UPDATE CHECKS PASSED"
