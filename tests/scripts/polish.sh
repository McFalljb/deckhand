#!/bin/sh
# Command palette, blended title bar, text input (run with this script):
# a fake pi store with neutral projects and a fake pi per tab (the fake
# bridge of panels.sh). Screenshots go to build/shots/polish/.
# Usage: tests/scripts/polish.sh [SCRIPT]   (default tests/scripts/polish.txt)
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
SCRIPT=${1:-tests/scripts/polish.txt}
FAKE_HOME="$ROOT/build/polish-home"
STORE="$FAKE_HOME/.pi/agent/sessions"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$STORE"

# session PROJECT HOURS-AGO ID TITLE
session() {
  d="$STORE/--code-$1--"
  mkdir -p "$d" "$FAKE_HOME/code/$1"
  ts=$(date -u -v-"$2"H +%Y-%m-%dT%H-%M-%S-000Z)
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' \
    "$3" "$FAKE_HOME/code/$1" "$4" > "$d/${ts}_$3.jsonl"
}
session recipe-box 40 r1 "Import recipes from a CSV export"
session recipe-box 90 r2 "Why does the search index miss accents?"
session garden-planner 20 g1 "Frost dates per planting zone"
session pi-desk 1 aaaa-1 "Command palette ranking"
session pi-desk 3 bbbb-2 "Blend the title bar into the top bar"
session pi-desk 26 cccc-3 "Double-click selects a word in the terminal"

HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$SCRIPT" DECKHAND_BIN="$ROOT/build/deckhand" \
  DECKHAND_CMD="exec sh '$ROOT/tests/scripts/fake-bridge.sh' \"\$@\"" \
  build/deckhand "$FAKE_HOME/code/pi-desk"
