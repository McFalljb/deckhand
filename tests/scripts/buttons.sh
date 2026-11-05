#!/bin/sh
# Every button of the top bar, the settings popover, the shortcuts sheet, the
# tab strip and the left column's rows, clicked in test mode: a fake HOME and
# pi store, a fake pi that prints its arguments, a temp data dir (never the
# user's). Also tooltips (label and shortcut from the action table) and idle
# CPU with the pointer resting on a button.
# Screenshots go to build/shots/buttons/. Usage: tests/scripts/buttons.sh [SCRIPT]
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
SCRIPT=${1:-tests/scripts/buttons.txt}
W="$ROOT/build/buttons"
rm -rf "$W"
FAKE_HOME="$W/home"
STORE="$FAKE_HOME/.pi/agent/sessions"
mkdir -p "$STORE" "$W/data" "$FAKE_HOME/Chats-elsewhere"

# session PROJECT HOURS-AGO ID TITLE
session() {
  d="$STORE/--code-$1--"
  mkdir -p "$d" "$FAKE_HOME/code/$1"
  ts=$(date -u -v-"$2"H +%Y-%m-%dT%H-%M-%S-000Z)
  f="$d/${ts}_$3.jsonl"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' \
    "$3" "$FAKE_HOME/code/$1" "$4" > "$f"
  touch -t "$(date -v-"$2"H +%Y%m%d%H%M.%S)" "$f"
}
session alpha 3 a1 "Write the release notes"
session alpha 9 a2 "Bump the parser"
session bravo 30 b1 "Fix the flaky test"

HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$SCRIPT" PI_DESK_DATA_DIR="$W/data" \
  PI_DESK_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "buttons scene failed (log: $W/run.log)"
  exit 1
fi
