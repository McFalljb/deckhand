#!/bin/sh
# End to end with real pi and the pi-kit bridge pi loads (pi-kit's
# extensions/desk-bridge, from the user's pi settings): pi in a pi-desk tab
# connects, sees the `panels` capability, hides its terminal sidebar and
# publishes shells and todos to the right column. Like looks.sh, pi runs with
# the real HOME (its login and packages) on a cheap model and writes its
# session into a fake store. Two short prompts. Screenshots: build/shots/panels/e2e-*.
# Usage: tests/scripts/bridge-e2e.sh [SCRIPT]   (default tests/scripts/bridge-e2e.txt)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SCRIPT=${1:-tests/scripts/bridge-e2e.txt}
FAKE_HOME="$ROOT/build/e2e-home"
PROJ="$FAKE_HOME/code/demo"
STORE="$FAKE_HOME/.pi/agent/sessions/--code-demo--"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$PROJ" "$STORE"
PI=$(command -v pi)
REAL_HOME=$HOME
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$SCRIPT" \
  PI_DESK_CMD="HOME='$REAL_HOME' exec '$PI' --model opencode-go/deepseek-v4.1-flash --session-dir '$STORE' \"\$@\"" \
  build/pi-desk "$PROJ"
