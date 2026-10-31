#!/usr/bin/env bash
# Runs the headless test suite with an isolated user:// directory.
# Usage: tests/run_tests.sh [suite-name-fragment]
set -euo pipefail
cd "$(dirname "$0")/.."
GODOT="${GODOT:-godot}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export XDG_DATA_HOME="$SANDBOX/data"
export XDG_CONFIG_HOME="$SANDBOX/config"
ARGS=()
if [[ $# -gt 0 ]]; then ARGS=(-- "suite=$1"); fi
"$GODOT" --headless --import >/dev/null 2>&1 || true
"$GODOT" --headless res://tests/test_runner.tscn "${ARGS[@]}"
