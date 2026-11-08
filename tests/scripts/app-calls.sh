#!/bin/sh
# App tabs under load at startup (test mode, quiet): the fake app (tests/fake-app/) opened ROUNDS
# times; each time agents' app_calls go out every 10 ms while it starts and says hello (each ends
# with tab_gone before it is connected, or its reply), then CALLS more once it is up.
# Every call must finish (the app's reply, or a timeout error: never a hang), and the app must
# read its hello reply before any other line (it exits otherwise: "a line before the hello reply").
# First, test mode's default backing scale: 1 on any Mac (an app screenshot's px are logical px).
# Usage: tests/scripts/app-calls.sh [ROUNDS] [CALLS]   (defaults 20, 20)
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
[ -x build/fake-app ] || { echo "build/fake-app missing: ./build.sh test (or ./build.sh fake-app)"; exit 1; }
ROUNDS=${1:-20}
CALLS=${2:-20}
W="$ROOT/build/app-calls"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"aaaa-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_aaaa-1.jsonl"
S="$W/script.txt"
{
  echo "wait 1500"
  echo "window front"
  # the backing scale is test mode's default (1) on any Mac: a screenshot's px are logical px
  echo "app_open build/fake-app"
  echo "app_waitframe 3 5000"
  echo "command {\"type\":\"app_screenshot\",\"tab_id\":\$last,\"rect\":{\"x\":0,\"y\":0,\"w\":100,\"h\":50}}"
  echo "assert_finished data.w 100"
  echo "assert_finished data.h 50"
  echo "command {\"type\":\"close_tab\",\"tab_id\":\$last}"
  echo "wait 100"
  r=0
  while [ $r -lt "$ROUNDS" ]; do
    echo "app_open build/fake-app"
    # calls every 10 ms while the app starts, so some land as it says hello: each ends at once
    # with tab_gone (not connected yet) or with the app's reply; none may hang or reach the app
    # before its hello reply (it would exit, and the waitlog below would fail)
    j=0
    while [ $j -lt 30 ]; do
      echo "command {\"type\":\"app_call\",\"tab_id\":\$last,\"method\":\"game.get\",\"params\":{\"path\":\"tick\"},\"timeout_ms\":3000}"
      echo "wait 10"
      j=$((j + 1))
    done
    echo "app_waitlog hello ok 5000"
    i=0
    while [ $i -lt "$CALLS" ]; do
      echo "command {\"type\":\"app_call\",\"tab_id\":\$last,\"method\":\"game.get\",\"params\":{\"path\":\"tick\"},\"timeout_ms\":3000}"
      echo "assert_finished ok true"
      i=$((i + 1))
    done
    echo "assert_not_app_log a line before the hello reply"
    echo "command {\"type\":\"close_tab\",\"tab_id\":\$last}"
    echo "wait 100"
    r=$((r + 1))
  done
  echo "quit"
} > "$S"
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$S" DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_RUNTIME_DIR="$W/run" DECKHAND_CMD='exec sleep 600' build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command" "$W/run.log" | head -20 || true
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "app-calls scene failed (log: $W/run.log)"; exit 1
fi
echo "app-calls scene ok"
