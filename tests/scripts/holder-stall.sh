#!/bin/sh
# A core the session holder dropped while both still run (#108): a laptop's sleep or a long stall
# leaves the core silent past the holder's pong timeout (30 s), and the holder drops it. Here the
# core is stopped (SIGSTOP) instead of the Mac sleeping. Run 1 starts a separate core with
# keep_sessions on and a fake pi (a tick every 0.3 s; it echoes what it reads), and closes the
# window. The scene stops the core until holder.log says it dropped it (the supervisor may launch
# a core meanwhile: refused, the stopped one holds core.lock), then continues it. Checks: the core
# attached to the same holder again (core.log), never "lost" it; run 2's window attaches to that
# same core, whose pi tab still runs: same pi process, its ticks went on, typed input reaches it
# and its answer comes back. Same holder, same session processes, nothing started twice.
# A fake HOME, a fake pi, a temp data dir and a short runtime dir (never the user's).
# Usage: tests/scripts/holder-stall.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/holder-stall"
rm -rf "$W" "$ROOT"/build/holder-stall-[12].txt
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkhs.XXXXXX") # sockets' paths must fit in sun_path
APP=
CORE=
cores() { pgrep -f "deckhand-core-serve serve --run $RUN" || true; }
holders() { pgrep -f "deckhand-core hold --run $RUN" || true; }
pis() { pgrep -f "holder-stall-pi $RUN" | sort | tr '\n' ' ' || true; }
cleanup() {
  [ -n "$CORE" ] && kill -CONT "$CORE" 2>/dev/null || true
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  cp "$RUN/holder.log" "$W/holder.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  for p in $(cores); do kill -9 "$p" 2>/dev/null || true; done
  for p in $(holders); do kill -9 "$p" 2>/dev/null || true; done
  pkill -9 -f "holder-stall-pi $RUN" 2>/dev/null || true
  rm -rf "$RUN"
}
trap cleanup EXIT
FAKE_HOME="$W/home"
PROJ="$W/proj"
SESS="$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--"
mkdir -p "$PROJ" "$W/data" "$SESS"
printf '{"type":"session","version":3,"id":"ssss-1","cwd":"%s"}\n' "$PROJ" > "$SESS/2026-11-01T10-00-00-000Z_ssss-1.jsonl"
start() { # n: a window in the background (APP: its pid)
  env HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="tests/scripts/holder-stall-$1.txt" \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
    DECKHAND_CMD="while [ \"\${1:-}\" = -e ]; do shift 2; done; echo ARGS: pi; exec sh -c '( i=0; while :; do i=\$((i+1)); echo stall-tick \$i pid \$\$; sleep 0.3; done ) & while read l; do echo got:\$l pid \$\$; done' holder-stall-pi $RUN" \
    build/deckhand > "$W/run$1.log" 2>&1 &
  APP=$!
}
finish() { # n: the window ended without a failed check
  wait "$APP" || true
  APP=
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run$1.log" || ! grep -q "done:" "$W/run$1.log"; then
    echo "holder-stall run $1 failed (log: $W/run$1.log)"; tail -20 "$W/run$1.log"; tail -30 "$RUN/core.log" 2>/dev/null; exit 1
  fi
}
wait_for() { # FILE TEXT SECONDS
  for _ in $(seq $(($3 * 10))); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  echo "no \"$2\" in $1 within $3 s"; tail -20 "$1" 2>/dev/null; exit 1
}

start 1; finish 1
CORE=$(cores)
HOLDER=$(holders)
[ -n "$CORE" ] && [ -n "$HOLDER" ] || { echo "after run 1: core '$CORE', holder '$HOLDER'"; cat "$RUN/core.log"; exit 1; }
KIDS=$(pgrep -P "$HOLDER" | sort | tr '\n' ' ')
PIS=$(pis)
[ -n "$KIDS" ] && [ -n "$PIS" ] || { echo "the holder runs no session (kids '$KIDS', pi '$PIS')"; exit 1; }

# the stall: nothing from the core for longer than the holder's pong timeout
kill -STOP "$CORE"
wait_for "$RUN/holder.log" "dropping the core: no frame within the pong timeout" 50
sleep 2 # the supervisor's first relaunch (after 1 s) is refused: the stopped core holds core.lock
kill -CONT "$CORE"
wait_for "$RUN/core.log" "session holder: attached again" 15
cp "$RUN/core.log" "$W/core.log"; cp "$RUN/holder.log" "$W/holder.log"
grep -q "session holder lost" "$W/core.log" && { echo "the core lost the holder"; tail -20 "$W/core.log"; exit 1; }
[ "$(cores)" = "$CORE" ] || { echo "the core changed: $CORE -> $(cores)"; exit 1; }
[ "$(holders)" = "$HOLDER" ] || { echo "the holder changed: $HOLDER -> $(holders)"; exit 1; }

start 2; finish 2
grep -q "core: attached to pid $CORE" "$W/run2.log" || { echo "run 2 did not attach to the same core $CORE"; grep "core:" "$W/run2.log"; exit 1; }
[ "$(cores)" = "$CORE" ] || { echo "the core changed after run 2: $CORE -> $(cores)"; exit 1; }
[ "$(holders)" = "$HOLDER" ] || { echo "the holder changed after run 2"; exit 1; }
[ "$(pgrep -P "$HOLDER" | sort | tr '\n' ' ')" = "$KIDS" ] || { echo "the sessions changed: $KIDS -> $(pgrep -P "$HOLDER" | sort | tr '\n' ' ')"; exit 1; }
[ "$(pis)" = "$PIS" ] || { echo "the pi processes changed (a second pi?): $PIS -> $(pis)"; exit 1; }
cp "$RUN/core.log" "$W/core.log"
python3 - "$ROOT/build/holder-stall-1.txt" "$ROOT/build/holder-stall-2.txt" <<'PY'
import re, sys
d1, d2 = (open(p).read() for p in sys.argv[1:])
t1 = [(int(t), p) for t, p in re.findall(r"stall-tick (\d+) pid (\d+)", d1)]
t2 = [(int(t), p) for t, p in re.findall(r"stall-tick (\d+) pid (\d+)", d2)]
got = re.findall(r"got:after-stall pid (\d+)", d2)
fail = []
pids = {p for _, p in t1 + t2} | set(got)
if len(pids) != 1: fail.append(f"pi processes: {sorted(pids)}")
if not t1 or not t2 or max(t for t, _ in t2) <= max(t for t, _ in t1) + 30: fail.append(f"the ticks did not go on through the stall: {max([t for t, _ in t1] or [0])} -> {max([t for t, _ in t2] or [0])}")
if not got: fail.append("the typed line never came back")
if fail: sys.exit("\n".join(fail))
print(f"one pi ({pids.pop()}): tick {max(t for t, _ in t1)} before the stall, {max(t for t, _ in t2)} after; input and output through the rejoined holder")
PY
kill -TERM "$CORE"
for _ in $(seq 50); do [ -z "$(cores)" ] && break; sleep 0.1; done
[ -z "$(cores)" ] || { echo "the core did not stop on SIGTERM"; exit 1; }
CORE=
echo "holder-stall: ok"
