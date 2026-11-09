#!/bin/sh
# The core loop runs when frames don't (src/core/core_loop.odin; docs/plans/background-core.md
# §10.2, M2-C): tests/scripts/hidden-window.txt hides the app while a fake pi
# (tests/scripts/fake-pi-flood.py) prints 20 MiB and asks a question and a shell exits, all in the
# session holder. While hidden, the state shows the exit and the question and the bell fires; frames
# stopped and the core loop's timer ticked instead; once shown, every terminal's screen hash is the
# one it had while hidden. A fake HOME, a temp data dir and a short runtime dir under $TMPDIR (never
# the user's); the holder and its children are gone when it ends, however it ends. Run 2
# (hidden-window-2.txt): a quit while hidden ends the app within 10 s; run 3 (hidden-window-3.txt):
# so does one while no frames run.
# Usage: tests/scripts/hidden-window.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/hidden-window"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkhw.XXXXXX") # the holder's socket path must fit in sun_path
APP=
holders() { pgrep -f "deckhand-core hold --run $RUN" || true; }
cleanup() {
  cp "$RUN/holder.log" "$W/holder.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  for p in $(holders); do pkill -9 -P "$p" 2>/dev/null || true; kill -9 "$p" 2>/dev/null || true; done
  pkill -9 -P 1 -f "$ROOT/tests/scripts/fake-pi-flood.py" 2>/dev/null || true # one the holder left behind
  rm -rf "$RUN"
}
trap cleanup EXIT INT TERM
FAKE_HOME="$W/home"
PROJ="$W/proj"
SESS="$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--"
mkdir -p "$PROJ" "$W/data" "$W/data2" "$W/data3" "$SESS"
printf '{"type":"session","version":3,"id":"hhhh-1","cwd":"%s"}\n' "$PROJ" > "$SESS/2026-11-08T10-00-00-000Z_hhhh-1.jsonl"

HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/hidden-window.txt DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
  DECKHAND_CMD="exec python3 -I '$ROOT/tests/scripts/fake-pi-flood.py' \"\$@\"" build/deckhand > "$W/run.log" 2>&1 &
APP=$!
wait "$APP" || true
APP=
grep -E "ASSERT FAILED|TIMEOUT|no element|unknown command|core_loop|screen_hash|notify:" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "workspace save checks" "$W/run.log"; then
  echo "hidden-window scene failed (log: $W/run.log)"; exit 1
fi
python3 - "$W/run.log" "$ROOT/build/hidden-window-before.json" <<'PY'
import json, re, sys
log = open(sys.argv[1]).read()
fail = []
tabs = json.load(open(sys.argv[2]))["open_sessions"][0]["tabs"]
if len(tabs) != 2 or not all(t.get("held") for t in tabs): fail.append(f"want 2 tabs in the session holder: {[(t.get('title'), t.get('held')) for t in tabs]}")
# core_loop lines: behind, hidden 1 s, the end of the hidden part, shown again
loops = [tuple(map(int, m)) for m in re.findall(r"core_loop timer_ticks (\d+) skipped (\d+) frames_called (\d+) frames_drawn (\d+)", log)]
if len(loops) != 4: fail.append(f"{len(loops)} core_loop lines, want 4")
else:
    (t0, _, f0, _), (t1, _, f1, _), (t2, _, f2, _), (t3, _, f3, _) = loops
    # about 20 a second while frames are off (the 1 s wait, then the flood): at least 10
    if t2 - t0 < 10: fail.append(f"the timer ticked {t2 - t0} times while frames were off, want 10 or more")
    if f2 != f0: fail.append(f"{f2 - f0} frames while frames were off")
    if f3 - f2 < 5: fail.append(f"{f3 - f2} frames after unhide: the window did not come back")
    print(f"hidden: {t2 - t0} timer ticks ({t2 - t1} after the flood began), {f2 - f0} frames; shown: {f3 - f2} frames, {t3 - t2} timer ticks")
hashes = re.findall(r"\[autotest\] screen_hash (\d+) (\d+) (\w+)", log)
if len(hashes) != 4: fail.append(f"{len(hashes)} screen_hash lines, want 2 terminals twice")
else:
    hidden, shown = dict((a, h) for a, _, h in hashes[:2]), dict((a, h) for a, _, h in hashes[2:])
    if hidden != shown: fail.append(f"screen hashes changed once shown: {hidden} -> {shown}")
if "[autotest] notify:" not in log: fail.append("no OS notification while hidden")
if fail: sys.exit("\n".join(fail))
print("hidden-window: state, bell and screens current while hidden")
PY
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(holders)" ] && break; sleep 0.3; done
[ -z "$(holders)" ] || { echo "the session holder still runs after Quit and Stop All Sessions"; exit 1; }

# 2 and 3: a quit while hidden, and one while no frames run (not hidden): the app is gone within
# 10 s (hidden-window-2.txt, hidden-window-3.txt)
quit_run() { # n what
  HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="tests/scripts/hidden-window-$1.txt" DECKHAND_DATA_DIR="$W/data$1" DECKHAND_RUNTIME_DIR="$RUN" \
    build/deckhand > "$W/run$1.log" 2>&1 &
  APP=$!
  for _ in $(seq 100); do grep -q '"type":"quit"' "$W/run$1.log" 2>/dev/null && break; sleep 0.1; done
  gone=
  for _ in $(seq 100); do kill -0 "$APP" 2>/dev/null || { gone=1; break; }; sleep 0.1; done
  if [ -z "$gone" ]; then
    echo "run $1: still running 10 s after a quit $2 (log: $W/run$1.log)"; exit 1
  fi
  wait "$APP" || true
  APP=
  if grep -qE "ASSERT FAILED|TIMEOUT|unknown command" "$W/run$1.log" || ! grep -q "workspace save checks" "$W/run$1.log"; then
    echo "run $1 failed (log: $W/run$1.log)"; exit 1
  fi
  echo "run $1: a quit $2 ended the app"
}
quit_run 2 "while hidden"
quit_run 3 "while no frames run"
echo "hidden-window scene ok"
