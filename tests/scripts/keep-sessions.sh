#!/bin/sh
# keep_sessions (holder_client.odin, holder_adopt.odin; docs/plans/background-core.md §7.2): run 1
# turns the setting on, starts a session with 6 shells printing counters and quits mid-output;
# the session holder (build/deckhand-core, spawned directly: test mode never uses launchd) keeps
# them running. Run 2 relaunches: every terminal is adopted from its snapshot, its screen hash
# equal to the one at the handover and, against a reference terminal fed every byte, equal with
# the probes; the same processes (pids) run on and the counters kept counting. Run 2 quits with
# "Quit and Stop All Sessions": the holder must be gone after it. A fake HOME, a fake pi, a temp
# data dir and a short runtime dir under $TMPDIR (never the user's).
# Usage: tests/scripts/keep-sessions.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/keep-sessions"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkks.XXXXXX") # the holder's socket path must fit in sun_path
holders() { pgrep -f "deckhand-core hold --run $RUN" || true; }
cleanup() {
  cp "$RUN/holder.log" "$W/holder.log" 2>/dev/null || true # the holder's stderr, for a failed run
  for p in $(holders); do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$RUN"
}
trap cleanup EXIT
FAKE_HOME="$W/home"
PROJ="$W/proj"
SESS="$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--"
mkdir -p "$PROJ" "$W/data" "$SESS"
printf '{"type":"session","version":3,"id":"kkkk-1","cwd":"%s"}\n' "$PROJ" > "$SESS/2026-11-01T10-00-00-000Z_kkkk-1.jsonl"
run() { # n
  HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="tests/scripts/keep-sessions-$1.txt" PI_DESK_DATA_DIR="$W/data" PI_DESK_RUNTIME_DIR="$RUN" \
    PI_DESK_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand > "$W/run$1.log" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command|session holder" "$W/run$1.log" | sed "s/^/run $1: /" || true
  # both runs end at their quit (no "done:"): the last line is the final save
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run$1.log" || ! grep -qE "workspace save checks" "$W/run$1.log"; then
    echo "keep-sessions run $1 failed (log: $W/run$1.log)"; exit 1
  fi
}
run 1
[ -n "$(holders)" ] || { echo "no session holder running after run 1"; cat "$RUN/holder.log" 2>/dev/null; exit 1; }
grep -q '"held":' "$W/data/workspace.json" || { echo "no held ids saved"; cat "$W/data/workspace.json"; exit 1; }
[ -f "$W/data/handover.json" ] || { echo "no handover.json"; exit 1; }
run 2
python3 - "$W/run1.log" "$W/run2.log" "$ROOT/build/keep-sessions-before.json" "$ROOT/build/keep-sessions-after.json" "$ROOT/build/keep-sessions-before.txt" "$ROOT/build/keep-sessions-after.txt" <<'PY'
import json, re, sys
log1, log2 = open(sys.argv[1]).read(), open(sys.argv[2]).read()
handed = {m[0]: m[1] for m in re.findall(r"\[autotest\] handover (\d+) offset \d+ hash (\w+)", log1)}
adopted = {m[0]: (m[1], m[2]) for m in re.findall(r"\[autotest\] adopted (\d+) hash (\w+) (exact|inexact)", log2)}
refs = dict(re.findall(r"\[autotest\] adopted_ref (\d+) (\w+)", log2))
fail = []
if len(handed) != 7: fail.append(f"{len(handed)} terminals handed over, want 7 (the pi tab and 6 shells)")
for term, h in handed.items():
    if term not in adopted: fail.append(f"terminal {term} not adopted"); continue
    if adopted[term] != (h, "exact"): fail.append(f"terminal {term}: handover hash {h}, adopted {adopted[term]}")
    if refs.get(term) != "equal": fail.append(f"terminal {term}: against the reference: {refs.get(term)}")
def tabs(p):
    return {t["title"]: t for t in json.load(open(p))["open_sessions"][0]["tabs"]}
before, after = tabs(sys.argv[3]), tabs(sys.argv[4])
for title, t in before.items():
    a = after.get(title)
    if not a or not t.get("held"): fail.append(f"{title}: not held, or gone"); continue
    if a.get("pid") != t.get("pid") or a.get("held") != t.get("held"): fail.append(f"{title}: pid/held {t.get('pid')}/{t.get('held')} -> {a.get('pid')}/{a.get('held')}")
    if a.get("inexact") or a["status"] != "running": fail.append(f"{title}: {a}")
def last(p):
    n = [int(x) for x in re.findall(r"t6 c(\d+)", open(p).read())]
    return max(n) if n else -1
if not last(sys.argv[6]) > last(sys.argv[5]) > 0: fail.append(f"the counter did not go on: {last(sys.argv[5])} -> {last(sys.argv[6])}")
if fail: sys.exit("\n".join(fail))
print(f"{len(handed)} terminals adopted exactly, same pids, counter {last(sys.argv[5])} -> {last(sys.argv[6])}")
PY
# Quit and Stop All Sessions: the holder hangs up and exits (shutdown waits up to 1 s to reap)
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(holders)" ] && break; sleep 0.3; done
[ -z "$(holders)" ] || { echo "the session holder still runs after Quit and Stop All Sessions"; exit 1; }
[ ! -f "$W/data/handover.json" ] || { echo "handover.json left after it was read"; exit 1; }
echo "keep-sessions scene ok"
