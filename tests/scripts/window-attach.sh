#!/bin/sh
# Window attach (docs/plans/background-core.md §10.3 M4-D, §12 "Window attach"), with a separate
# core (DECKHAND_SEPARATE_CORE=1) and keep_sessions on:
# 1. the window starts a session whose fake pi is in a turn (a tick every 0.2 s), and is killed
#    (-9) mid-turn: the core and the turn run on.
# 2. a new window attaches to the same core: the same pi process, its turn further along, on screen.
#    Then the core is killed (-9): the window does not quit. It launches a core again, which adopts
#    the turn from the session holder, and shows it from a fresh state.full: same pi process,
#    further along still. Then that core gets a plain SIGTERM (its handover and save hold core.lock
#    while the window dials): the window reconnects again, to the core it relaunches.
# A fake HOME, a fake pi, a temp data dir and a short runtime dir (never the user's).
# Usage: tests/scripts/window-attach.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/window-attach"
rm -rf "$W" "$ROOT"/build/window-attach-[1234].txt
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkwa.XXXXXX") # core.sock's path must fit in sun_path
APP=
cores() { pgrep -f "deckhand-core-serve serve --run $RUN" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  for p in $(cores); do kill -9 "$p" 2>/dev/null || true; done
  pkill -9 -f "deckhand-core hold --run $RUN" 2>/dev/null || true
  pkill -9 -f "window-attach-pi $RUN" 2>/dev/null || true
  rm -rf "$RUN"
}
trap cleanup EXIT
FAKE_HOME="$W/home"
PROJ="$W/proj"
SESS="$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--" # a pi session to open: an open one is saved
mkdir -p "$PROJ" "$W/data" "$SESS"
printf '{"type":"session","version":3,"id":"wwww-1","cwd":"%s"}\n' "$PROJ" > "$SESS/2026-11-01T10-00-00-000Z_wwww-1.jsonl"
start() { # n: a window in the background (APP: its pid)
  env HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="tests/scripts/window-attach-$1.txt" \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
    DECKHAND_CMD="while [ \"\${1:-}\" = -e ]; do shift 2; done; echo ARGS: pi; exec sh -c 'i=0; while :; do i=\$((i+1)); echo turn-tick \$i pid \$\$; sleep 0.2; done' window-attach-pi $RUN" \
    build/deckhand > "$W/run$1.log" 2>&1 &
  APP=$!
}
wait_for() { # FILE TEXT SECONDS
  for _ in $(seq $(($3 * 10))); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  echo "no \"$2\" in $1 within $3 s"; tail -20 "$1" 2>/dev/null; exit 1
}
failed() { grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run$1.log"; }

start 1
wait_for "$W/run1.log" "core: attached to pid" 20
CORE=$(cores)
wait_for "$ROOT/build/window-attach-1.txt" "turn-tick" 20
! failed 1 || { echo "run 1 failed"; tail -20 "$W/run1.log"; exit 1; }
kill -9 "$APP"; wait "$APP" 2>/dev/null || true; APP=
sleep 1
[ "$(cores)" = "$CORE" ] || { echo "the core did not run on after the window was killed ($CORE -> $(cores))"; exit 1; }

start 2
wait_for "$W/run2.log" "core: attached to pid $CORE" 20
wait_for "$ROOT/build/window-attach-2.txt" "turn-tick" 20
kill -9 "$CORE"
wait_for "$W/run2.log" "core: reattached to pid" 20
wait_for "$ROOT/build/window-attach-3.txt" "turn-tick" 30
MID=$(cores)
kill -TERM "$MID" # a plain stop: its handover and save hold core.lock while the window dials
for _ in $(seq 200); do [ "$(grep -c "core: reattached to pid" "$W/run2.log")" -ge 2 ] && break; sleep 0.1; done
[ "$(grep -c "core: reattached to pid" "$W/run2.log")" -ge 2 ] || { echo "no reconnect after the core's SIGTERM"; tail -20 "$W/run2.log"; exit 1; }
wait "$APP" || true; APP=
if failed 2 || ! grep -q "done:" "$W/run2.log"; then echo "run 2 failed (log: $W/run2.log)"; tail -20 "$W/run2.log"; exit 1; fi
NEW=$(cores)
[ -n "$NEW" ] && [ "$NEW" != "$CORE" ] && [ "$NEW" != "$MID" ] || { echo "no new core after the kill ($CORE -> ${NEW:-none})"; exit 1; }
python3 - "$ROOT/build/window-attach-1.txt" "$ROOT/build/window-attach-2.txt" "$ROOT/build/window-attach-3.txt" "$ROOT/build/window-attach-4.txt" <<'PY'
import re, sys
dumps = [open(p).read() for p in sys.argv[1:]]
got = [[(int(t), p) for t, p in re.findall(r"turn-tick (\d+) pid (\d+)", d)] for d in dumps]
pids = [sorted({p for _, p in g}) for g in got]
ticks = [max([t for t, _ in g] or [0]) for g in got]
fail = []
if len(pids[0]) != 1 or any(p != pids[0] for p in pids): fail.append(f"the pi process: {pids}")
if not (ticks[0] < ticks[1] < ticks[2] < ticks[3]): fail.append(f"the turn did not go on: last ticks {ticks}")
if fail: sys.exit("\n".join(fail))
print(f"one turn (pi {pids[0][0]}): tick {ticks[0]}, window killed, tick {ticks[1]} in a new window, core killed, tick {ticks[2]} after the reconnect, core stopped (SIGTERM), tick {ticks[3]} after the next")
PY
kill -TERM "$NEW"
for _ in $(seq 50); do [ -z "$(cores)" ] && break; sleep 0.1; done
[ -z "$(cores)" ] || { echo "the core did not stop on SIGTERM"; exit 1; }
echo "window-attach: ok"
