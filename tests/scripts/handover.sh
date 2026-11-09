#!/bin/sh
# Core handover with a core process on each side (docs/plans/background-core.md §7.2, §10.3 M4-E):
# run 1, a window with a separate core (DECKHAND_SEPARATE_CORE=1) turns keep_sessions on, starts a
# counting shell (in the session holder) and a job run (a fake `pi --mode json`, SLOW 4), and
# closes. Run 2's window finds that core and hands it over (DECKHAND_CORE_HANDOVER=self: test mode
# installs nothing, so the successor is the same binary): the old core waits for the job run to end,
# says GOODBYE{handover, successor}, snapshots, and launches its successor with the holder's secret;
# the window dials the new core. Checks: a new core pid, the same holder and session pids, every held
# terminal adopted exact from the handover's snapshot, the job run recorded ok (not stopped), and no
# 64-hex secret in any log. Then the core is killed (-9): the holder's supervisor launches it again. A fake HOME, fake pi, temp data dir and a short runtime dir.
# Usage: tests/scripts/handover.sh
set -eu
unset CLAUDE_CONFIG_DIR
unset PI_KIT_NOTES_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/handover"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkho.XXXXXX") # sockets' paths must fit in sun_path
APP=
cores() { pgrep -f "deckhand-core-serve serve --run $RUN" || true; }
holders() { pgrep -f "deckhand-core hold --run $RUN" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  cp "$RUN/holder.log" "$W/holder.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  for p in $(cores); do kill -9 "$p" 2>/dev/null || true; done
  for p in $(holders); do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$RUN"
}
trap cleanup EXIT
FAKE_HOME="$W/home"
PROJ="$W/proj"
NOTES="$FAKE_HOME/notes"
SESS="$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--"
mkdir -p "$PROJ" "$W/data" "$NOTES/jobs" "$FAKE_HOME/bin" "$SESS"
printf '{"type":"session","version":3,"id":"hhhh-1","cwd":"%s"}\n' "$PROJ" > "$SESS/2026-11-01T10-00-00-000Z_hhhh-1.jsonl"
cp tests/scripts/fake-pi-json.py "$FAKE_HOME/bin/pi"
chmod 755 "$FAKE_HOME/bin/pi"
printf -- '---\ntype: job\nid: slow1\nenabled: false\nschedule: "manual"\nnotify: never\n---\n# Job slow1\n\n## Prompt\nSLOW 4\n' > "$NOTES/jobs/slow.md"
printf '{"v":1,"settings":{"home_dir":"%s","setup_seen":true}}\n' "$NOTES" > "$W/data/workspace.json"
start() { # n [VAR=value...]
  n=$1; shift
  env "$@" HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="tests/scripts/handover-$n.txt" \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
    DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand > "$W/run$n.log" 2>&1 &
  APP=$!
}
finish() { # n: the window ended without a failed check
  wait "$APP" || true
  APP=
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run$1.log" || ! grep -q "done:" "$W/run$1.log"; then
    echo "handover run $1 failed (log: $W/run$1.log)"; tail -20 "$W/run$1.log"; cat "$RUN/core.log" 2>/dev/null | tail -30; exit 1
  fi
}
start 1; finish 1
OLD=$(cores)
HOLDER=$(holders)
[ -n "$OLD" ] && [ -n "$HOLDER" ] || { echo "after run 1: core '$OLD', holder '$HOLDER'"; cat "$RUN/core.log"; exit 1; }
KIDS=$(pgrep -P "$HOLDER" | sort | tr '\n' ' ')
[ -n "$KIDS" ] || { echo "the holder runs no session"; exit 1; }
start 2 DECKHAND_CORE_HANDOVER=self; finish 2
NEW=$(cores)
cp "$RUN/core.log" "$W/core.log"
[ -n "$NEW" ] && [ "$NEW" != "$OLD" ] || { echo "no new core: $OLD -> '$NEW'"; tail -40 "$W/core.log"; exit 1; }
kill -0 "$OLD" 2>/dev/null && { echo "the old core $OLD still runs"; exit 1; }
[ "$(holders)" = "$HOLDER" ] || { echo "the holder changed: $HOLDER -> $(holders)"; exit 1; }
[ "$(pgrep -P "$HOLDER" | sort | tr '\n' ' ')" = "$KIDS" ] || { echo "the sessions changed: $KIDS -> $(pgrep -P "$HOLDER" | sort | tr '\n' ' ')"; exit 1; }
grep -q "core: attached to pid $NEW" "$W/run2.log" || { echo "run 2 did not attach to the new core $NEW"; grep "core:" "$W/run2.log"; exit 1; }
grep -q "holder attached: previous handover, [0-9]* terminals, as the named successor" "$W/core.log" || { echo "the new core was not the holder's named successor"; grep "holder attached" "$W/core.log"; exit 1; }
python3 - "$W/core.log" "$W/data/jobs" "$W" <<'PY'
import glob, json, os, re, sys
log = open(sys.argv[1]).read()
fail = []
hand = dict(re.findall(r"\[autotest\] handover (\d+) offset \d+ hash (\w+)", log))
adopt = re.findall(r"\[autotest\] adopted (\d+) hash (\w+) (exact|inexact)", log)
if not hand: fail.append("no handover snapshot logged")
for t, h, how in adopt:
    if how != "exact": fail.append(f"terminal {t} adopted {how}")
    if t in hand and hand[t] != h: fail.append(f"terminal {t}: handover hash {hand[t]}, adopted {h}")
if not adopt: fail.append("nothing adopted by the new core")
metas = glob.glob(os.path.join(sys.argv[2], "slow1", "runs", "*", "meta.json"))
if len(metas) != 1: fail.append(f"job runs: {metas}")
else:
    st = json.load(open(metas[0])).get("status")
    if st != "ok": fail.append(f"the job run across the handover ended {st!r}")
for f in glob.glob(os.path.join(sys.argv[3], "*.log")):
    text = "\n".join(l for l in open(f, errors="replace").read().split("\n") if "DECKHAND_TOKEN=" not in l) # test mode's control tokens
    if re.search(r"\b[0-9a-f]{64}\b", text): fail.append(f"a 64-hex value in {f}")
if fail: sys.exit("\n".join(fail))
print(f"handed over: {len(adopt)} terminal(s) adopted exact, the job run ok")
PY
# the supervisor: a core killed with -9 is launched again by the holder (no window open)
kill -9 "$NEW"
AGAIN=
for _ in $(seq 100); do AGAIN=$(cores); [ -n "$AGAIN" ] && [ "$AGAIN" != "$NEW" ] && grep -q "holder attached: previous crash" "$RUN/core.log" && break; sleep 0.1; done
[ -n "$AGAIN" ] && [ "$AGAIN" != "$NEW" ] || { echo "the supervisor did not relaunch the core"; tail -20 "$RUN/holder.log"; exit 1; }
grep -q "holder attached: previous crash" "$RUN/core.log" || { echo "the relaunched core did not attach"; tail -20 "$RUN/core.log"; exit 1; }
[ "$(holders)" = "$HOLDER" ] || { echo "the holder changed after the crash"; exit 1; }
NEW=$AGAIN
kill -TERM "$NEW"
for _ in $(seq 50); do [ -z "$(cores)" ] && break; sleep 0.1; done
[ -z "$(cores)" ] || { echo "the new core did not stop on SIGTERM"; exit 1; }
echo "handover: ok"
