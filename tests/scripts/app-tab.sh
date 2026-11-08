#!/bin/sh
# App tabs in test mode (quiet: the window stays hidden): the fake app
# (tests/fake-app/, built by ./build.sh test) in an app tab. Frames arrive
# (pixels read back from the shown IOSurface: the square's colour and its
# position changing), keys and clicks reach the app (its log), a resize sends
# a new ring of the right size and the old one is freed, a stall keeps the
# last frame and Deckhand responsive, a crash leaves the dimmed frame and the
# Restart button, Restart draws again, exit 75 restarts by itself, and typing
# into Atlas's drawer sends the app nothing. Measures frame latency, CPU and memory.
# A fake HOME with one project and session, a fake pi, a temp data dir.
# Usage: tests/scripts/app-tab.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
# backing scale 2 on any Mac (test mode's default is 1): logical px vs ring px stays tested
export DECKHAND_SCALE=2
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
[ -x build/fake-app ] || { echo "build/fake-app missing: ./build.sh test (or ./build.sh fake-app)"; exit 1; }
W="$ROOT/build/app-tab"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
# the palette's "New app tab…" lists the project's apps
mkdir -p "$PROJ/.deckhand"
printf '{"apps":[{"name":"fake","argv":["%s/build/fake-app"]}]}\n' "$ROOT" > "$PROJ/.deckhand/apps.json"
printf '{"type":"session","version":3,"id":"aaaa-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_aaaa-1.jsonl"
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/app-tab.txt DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_RUNTIME_DIR="$W/run" APP_TAB_ONCE="$W" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand "$PROJ" > "$W/run.log" 2>&1 &
PID=$!
# Deckhand's memory while the scene runs (RSS, KB): before the first app tab
# (the script waits 1.5 s first) and the peak
peak=0; before=0; n=0
while kill -0 $PID 2>/dev/null; do
  r=$(ps -o rss= -p $PID 2>/dev/null | tr -d ' ')
  [ -n "$r" ] && [ "$r" -gt "$peak" ] && peak=$r
  [ -n "$r" ] && n=$((n + 1)) && [ $n = 2 ] && before=$r
  sleep 0.5
done
wait $PID || true
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|\[app\]|CPU " "$W/run.log" || true
echo "Deckhand RSS: $((before / 1024)) MB before the first app tab, peak $((peak / 1024)) MB"
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
if [ $fail = 1 ]; then echo "app-tab scene failed (log: $W/run.log)"; exit 1; fi
echo "app-tab scene ok"
