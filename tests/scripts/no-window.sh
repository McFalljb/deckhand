#!/bin/sh
# The core with no window (docs/plans/background-core.md §10.2, M3-G; M4's case, played now): test
# mode's detach_window, then every command a window hosts (pages, apps, Markdown and file views)
# answers {"ok":false} with data.code no_window at once, for agents and the user alike, while
# what the core keeps (state, the project's files, app status) still answers; attach_window, and
# the app tab, the Markdown tab and the editor answer again as before. No CEF page is loaded: a
# browser call is refused before it would need one. Quiet test mode, a fake HOME and pi, a temp
# data dir. Needs build/fake-app (./build.sh test). Usage: tests/scripts/no-window.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
[ -x build/fake-app ] || { echo "build/fake-app missing: ./build.sh test (or ./build.sh fake-app)"; exit 1; }
W="$ROOT/build/no-window"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"nnnn-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_nnnn-1.jsonl"
printf '# Notes\n\n## Later\n\ntext\n' > "$PROJ/notes.md"
printf 'one\ntwo\n' > "$PROJ/a.txt"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdn.XXXXXX") # a short runtime dir: the socket path must fit sun_path
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/no-window.txt DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_RUNTIME_DIR="$RUN" FAKE_APP="$ROOT/build/fake-app" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; exec sleep 600' build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "no-window scene failed (log: $W/run.log)"
  exit 1
fi
echo "no-window scene ok"
