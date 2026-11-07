#!/bin/sh
# Split panes in test mode (panes.odin, ui_panes.odin; docs/plans/split-panes.md P2):
# the script (default panes.txt; panes-capture.txt: pointer capture across panes; panes-drag.txt:
# dragging tabs).
# A fake HOME with one project and session, a fake pi, a temp data dir.
# Writes build/<script>/ and build/shots/<script>/.
# Usage: tests/scripts/panes.sh [panes-capture.txt | panes-drag.txt]
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
SCRIPT=${1:-panes.txt}
N=$(basename "$SCRIPT" .txt)
W="$ROOT/build/$N"
rm -rf "$W" "build/shots/$N"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"llll-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_llll-1.jsonl"
for i in $(seq 1 40); do echo "line $i of the notes"; done > "$PROJ/notes.txt" # panes-capture.txt's editor
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="tests/scripts/$SCRIPT" PI_DESK_DATA_DIR="$W/data" \
  PI_DESK_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "$N scene failed (log: $W/run.log)"; exit 1
fi
echo "$N scene ok"
