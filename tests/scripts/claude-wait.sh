#!/bin/sh
# claude_wait_idle in quiet test mode (tests/scripts/claude-wait.txt): Atlas's wait on a Claude tab,
# with a fake claude (tests/scripts/fake-claude.py, never a real one) whose OSC 7501 status lags its
# Stop hook. A fake HOME and pi, a temp data dir. Needs build/deckhand, build/deckhand-cli and
# build/claude-code (./build.sh). Writes build/claude-wait/ and build/shots/claude-wait/.
# Usage: tests/scripts/claude-wait.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/claude-wait"
rm -rf "$W" build/shots/claude-wait
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
[ -x build/deckhand ] || { echo "claude-wait scene: build/deckhand missing (./build.sh)"; exit 1; }
[ -x build/deckhand-cli ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/deckhand-cli or build/claude-code missing: ./build.sh"; exit 1; }
printf '{"type":"session","version":3,"id":"cccc-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_cccc-1.jsonl"
# a short runtime dir: the socket path must fit sun_path
# Claude Code "installed" (a stand-in, never run: the tab runs the fake below); test mode never
# looks at PATH (harness.odin detect_path)
. tests/scripts/claude-stub.sh
claude_stub "$FAKE_HOME"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdw.XXXXXX")
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/claude-wait.txt \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD='exec sleep 600' \
  DECKHAND_CLAUDE_CMD="exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\"" \
  FAKE_CLAUDE_LOG="$W/claude.log" FAKE_CLAUDE_SESSION=0c1a0de0-2222-4222-8333-444455556666 \
  FAKE_CLAUDE_TURN_MS=200 FAKE_CLAUDE_OSC_LAG_MS=1500 \
  build/deckhand > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q 'ui_command {"type":"quit","confirm"' "$W/run.log"; then
  echo "claude-wait scene failed (log: $W/run.log)"; exit 1
fi
echo "claude-wait scene ok"
