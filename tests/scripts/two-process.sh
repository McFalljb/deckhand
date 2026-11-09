#!/bin/sh
# Two processes (docs/plans/background-core.md §10.3 M4-C): the window with a separate core
# (DECKHAND_SEPARATE_CORE=1) launches `deckhand-core-serve serve` (test mode: directly), attaches
# over core.sock after the mutual checks, and runs a shell tab in it. The window closes (its quit);
# the core and the shell run on, and --ctl get_state still answers with no window. A second window
# attaches to the same core and shows the same terminal: the same shell (its pid printed), the
# same screen hash, and it still takes input. Then the core is stopped (SIGTERM): nothing is left.
# A fake HOME, a fake pi, a temp data dir and a short runtime dir (never the user's).
# Usage: tests/scripts/two-process.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/two-process"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dk2p.XXXXXX") # core.sock's path must fit in sun_path
APP=
cores() { pgrep -f "deckhand-core-serve serve --run $RUN" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  for p in $(cores); do kill -9 "$p" 2>/dev/null || true; done
  pkill -9 -f "deckhand-core hold --run $RUN" 2>/dev/null || true
  rm -rf "$RUN"
}
trap cleanup EXIT
FAKE_HOME="$W/home"
PROJ="$W/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME"
start() { # n [DIR]: a window in the background (APP: its pid); DIR: a new chat there (run 1)
  env HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="tests/scripts/two-process-$1.txt" \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
    DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand ${2:+"$2"} > "$W/run$1.log" 2>&1 &
  APP=$!
}
finish() { # n: the window ended without a failed check
  wait "$APP" || true
  APP=
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run$1.log" || ! grep -q "done:" "$W/run$1.log"; then
    echo "two-process run $1 failed (log: $W/run$1.log)"; tail -20 "$W/run$1.log"; exit 1
  fi
}
start 1 "$PROJ"; finish 1
grep -q "core: attached to pid" "$W/run1.log" || { echo "run 1: the window did not attach to a separate core"; exit 1; }
[ -n "$(cores)" ] || { echo "no core running after the window closed"; cat "$RUN/core.log" 2>/dev/null; exit 1; }
CORE=$(cores)
# no window: the core still answers (a control token from its log: test mode prints one)
TOK=$(sed -n "s/^export DECKHAND_SOCKET='\(.*\)' DECKHAND_TOKEN='\(.*\)'$/\2/p" "$RUN/core.log" | head -1)
[ -n "$TOK" ] || { echo "no control token in the core's log"; cat "$RUN/core.log"; exit 1; }
DECKHAND_SOCKET="$RUN/core.sock" DECKHAND_TOKEN="$TOK" build/deckhand --ctl '{"type":"get_state"}' > "$W/state.json"
grep -q '"open_sessions"' "$W/state.json" || { echo "--ctl get_state did not answer with no window"; head -c 400 "$W/state.json"; exit 1; }
start 2; finish 2
[ "$(cores)" = "$CORE" ] || { echo "run 2 did not use the same core ($CORE -> $(cores))"; exit 1; }
grep -q "core: attached to pid $CORE" "$W/run2.log" || { echo "run 2: not attached to core $CORE"; exit 1; }
python3 - "$W/run1.log" "$W/run2.log" "$ROOT/build/two-process-1.txt" "$ROOT/build/two-process-2.txt" <<'PY'
import re, sys
l1, l2 = open(sys.argv[1]).read(), open(sys.argv[2]).read()
d1, d2 = open(sys.argv[3]).read(), open(sys.argv[4]).read()
fail = []
pid1 = re.findall(r"MARK-42 (\d+)", d1)
pid2 = re.findall(r"MARK-42 (\d+)", d2)
if not pid1 or pid1 != pid2: fail.append(f"the shell's pid: {pid1} then {pid2}")
h1 = dict(re.findall(r"\[autotest\] screen_hash (\d+) view (\w+)", l1))
h2 = dict(re.findall(r"\[autotest\] screen_hash (\d+) view (\w+)", l2))
common = [t for t in h1 if t in h2]
if not common: fail.append(f"no terminal shown in both windows: {h1} {h2}")
for t in common:
    if h1[t] != h2[t]: fail.append(f"tab {t}: screen hash {h1[t]} then {h2[t]}")
if fail: sys.exit("\n".join(fail))
print(f"same shell (pid {pid1[0]}), same screen ({len(common)} terminal(s)) in a second window")
PY
kill -TERM "$CORE"
for _ in $(seq 50); do [ -z "$(cores)" ] && break; sleep 0.1; done
[ -z "$(cores)" ] || { echo "the core did not stop on SIGTERM"; exit 1; }
[ ! -e "$RUN/window.token" ] || { echo "window.token left after the core stopped"; exit 1; }
echo "two-process: ok"
