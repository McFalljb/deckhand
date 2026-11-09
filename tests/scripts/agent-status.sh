#!/bin/sh
# Agent status for every terminal tab (src/core/agent_status.odin): a fake agent
# (tests/scripts/fake-7501.py, never a real one) in a shell tab asks for and
# reports OSC 7501 program status; a fake pi that only sleeps. Checks the
# query/reply handshake, the dots on the tab, row, Open group and project,
# nested ids, malformed and oversized input, a new prompt and the program's
# exit clearing working, done → unseen → seen, Mark as unread / read from
# the row menu, the tooltip, and the attention sort. A temp data dir (never
# the user's). Screenshots go to build/shots/agent-status/.
# Usage: tests/scripts/agent-status.sh [SCRIPT]
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
. tests/scripts/claude-stub.sh
SCRIPT=${1:-tests/scripts/agent-status.txt}
W="$ROOT/build/agent-status"
rm -rf "$W"
FAKE_HOME="$W/home"
claude_stub "$FAKE_HOME" # Claude Code "installed": the menus read as with it (docs/CLAUDE.md §1)
PROJ="$FAKE_HOME/code/recipe-box"
DIR="$FAKE_HOME/.pi/agent/sessions/--status--"
mkdir -p "$PROJ" "$DIR" "$W/data"
cp tests/scripts/fake-7501.py "$FAKE_HOME/fake-7501.py"
# a log holding a report: `cat` prints it and is gone before Deckhand reads it
printf '\033]7501;state=blocked:kind=permission:app=spoof\007' > "$FAKE_HOME/evil.log"
i=0
for s in "aaaa-1|Import recipes from a CSV export" "bbbb-2|Which unit should the search index use"; do
  id=${s%%|*}; title=${s#*|}; i=$((i + 1))
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' \
    "$id" "$PROJ" "$title" > "$DIR/2026-10-2${i}T0${i}-00-00-000Z_$id.jsonl"
done
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$SCRIPT" DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' \
  build/deckhand > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "agent-status scene failed (log: $W/run.log)"
  exit 1
fi
