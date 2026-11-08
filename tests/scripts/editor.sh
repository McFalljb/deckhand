#!/bin/sh
# The editor end to end in test mode: a fake HOME with a git project, a fake pi
# that prints its arguments, a temp data dir (never the user's). Opens a file,
# types, undoes, saves (keys and toolbar), uses the right-click menu, then a
# shell tab changes the file on disk: clean -> reloaded, dirty -> banner.
# Also opens a 50k-line C file and measures idle CPU with an editor open.
# Screenshots go to build/shots/editor/. Usage: tests/scripts/editor.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/editor"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"eeee-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_eeee-1.jsonl"
printf 'int main(void) {\n    return 0;\n}\n' > "$PROJ/hello.c"
awk 'BEGIN { for (i = 0; i < 50000; i++) printf "int f%d(int x) { return x; } // %d\n", i, i }' > "$PROJ/big.c"
(cd "$PROJ" && git init -q && git add hello.c && git -c user.name=t -c user.email=t@example.invalid commit -qm init)
run() { # script log [args]
  s=$1; l=$2; shift 2
  HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$s" DECKHAND_DATA_DIR="$W/data" \
    DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand "$@" > "$l" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU" "$l" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$l" || ! grep -q "done:" "$l"; then
    echo "editor scene failed (log: $l)"; exit 1
  fi
}
echo "== run 1: open, edit, save, disk changes"
run tests/scripts/editor.txt "$W/run.log"
echo "== run 2: relaunch: editor tabs restored"
run tests/scripts/editor-2.txt "$W/run2.log"
echo "hello.c on disk:"; cat "$PROJ/hello.c"
