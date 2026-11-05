#!/bin/sh
# A pi tab whose process exits (tests/scripts/dead-tab.txt): the bar with how
# it ended, Restart, Restart with model… (pi's selector), and every way of
# opening the session restarting it. A fake HOME with one project and session,
# and a fake pi (tests/scripts/fake-pi-dead.py) that exits on "limit" (a
# rate-limit error, code 1) or "hup" (SIGHUP). Screenshots: build/shots/dead-tab/.
# Usage: tests/scripts/dead-tab.sh [SCRIPT]
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SCRIPT=${1:-tests/scripts/dead-tab.txt}
FAKE_HOME="$ROOT/build/dead-home"
PROJ="$FAKE_HOME/code/demo"
STORE="$FAKE_HOME/.pi/agent/sessions/--code-demo--"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$PROJ" "$STORE" build/shots/dead-tab
printf '{"type":"session","version":3,"id":"demo-1","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Fix the demo build"}}\n' "$PROJ" \
  > "$STORE/2026-10-30T10-00-00-000Z_demo-1.jsonl"
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$SCRIPT" \
  PI_DESK_CMD="exec python3 -I '$ROOT/tests/scripts/fake-pi-dead.py' \"\$@\"" \
  build/deckhand
