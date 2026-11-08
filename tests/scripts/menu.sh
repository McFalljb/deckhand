#!/bin/sh
# The menu bar in test mode (quiet: the window stays hidden): items picked by
# id as a click does, key presses through the menu bar's key equivalents
# (NSEvents built in-process, never posted to the system), enable and check
# rules, the terminal text size, the shortcuts sheet grouped like the menus.
# A fake HOME with one project and session, a fake pi, a temp data dir.
# Writes build/shots/menu/ (the native menu bar as text, screenshots).
# Usage: tests/scripts/menu.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/menu"
rm -rf "$W" build/shots/menu
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--" "$FAKE_HOME/Chats"
printf '{"type":"session","version":3,"id":"mmmm-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_mmmm-1.jsonl"
printf 'hello\n' > "$PROJ/a.txt"
# Claude Code "installed" (a stand-in, never run) and every Claude tab runs an echo instead: never a
# real claude, whatever this machine has on PATH (⌥⌘T, New session's picker)
. tests/scripts/claude-stub.sh
claude_stub "$FAKE_HOME"
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/menu.txt DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' DECKHAND_CLAUDE_CMD='echo "CLAUDE ARGS: $*"; exec sleep 600' build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|menu:|unknown command" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|no element|menu: |unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
[ "$(cat "$PROJ/a.txt")" = "xyhello" ] || { echo "a.txt not saved through the menu: $(cat "$PROJ/a.txt")"; fail=1; }
grep -q '"terminal_text_size":16' "$W/data/workspace.json" || { echo "the text size was not saved"; fail=1; }
if [ $fail = 1 ]; then echo "menu scene failed (log: $W/run.log)"; exit 1; fi
echo "menu scene ok"
