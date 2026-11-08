#!/bin/sh
# The bell (notification centre) with a fake bridge (tests/scripts/fake-bridge-bell.py):
# a fake pi store with two sessions whose fake pi reports working → idle and
# working → waiting; a temp data dir (never the user's). Checks the bell's
# entries, the OS notification stub, focus marks read, a click on an entry,
# the gear's toggles, narrow widths, light and dark, idle CPU.
# Screenshots go to build/shots/bell/. Usage: tests/scripts/bell.sh [SCRIPT]
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
SCRIPT=${1:-tests/scripts/bell.txt}
W="$ROOT/build/bell"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/code/recipe-box"
DIR="$FAKE_HOME/.pi/agent/sessions/--bell--"
mkdir -p "$PROJ" "$DIR" "$W/data"
i=0
for s in "aaaa-1|Import recipes from a CSV export" "bbbb-2|Which unit should the search index use?"; do
  id=${s%%|*}; title=${s#*|}; i=$((i + 1))
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' \
    "$id" "$PROJ" "$title" > "$DIR/2026-10-2${i}T0${i}-00-00-000Z_$id.jsonl"
done
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$SCRIPT" DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_CMD="exec python3 '$ROOT/tests/scripts/fake-bridge-bell.py' \"\$@\"" \
  build/deckhand > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU|notify:" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "bell scene failed (log: $W/run.log)"
  exit 1
fi
