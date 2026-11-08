#!/bin/sh
# keep_sessions (holder_client.odin, holder_adopt.odin; docs/plans/background-core.md §7.2, §7.7):
# 1. turns the setting on, starts a session (a fake pi holding a bridge connection,
#    fake-pi-keep.py) with 6 shells printing counters and quits mid-output;
#    the session holder (build/deckhand-core, spawned directly: test mode never uses launchd)
#    keeps them running.
# 2. relaunches: every terminal is adopted from its snapshot, its screen hash equal to the one at
#    the handover and, against a reference terminal fed every byte, equal with the probes; the
#    kept pi's bridge reconnects with its reconnect token (tokens.json). The palette's Restart
#    session holder upgrades the holder in place (§7.3); the same processes (pids) run on and the
#    counters kept counting. Then the app is killed (-9).
# 3. relaunches after that crash, its bundled holder taken for a newer one: adopted from the tails
#    (inexact), same pids, and the holder upgraded in place at attach, once; then "Quit
#    Deckhand and Stop All Sessions": the holder must be gone after it.
# 4. relaunches: fresh shells in a new holder, which is killed (-9): every tab says holder_lost.
# A fake HOME, a fake pi, a temp data dir and a short runtime dir under $TMPDIR (never the user's).
# Usage: tests/scripts/keep-sessions.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/keep-sessions"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkks.XXXXXX") # the holder's socket path must fit in sun_path
APP=
holders() { pgrep -f "deckhand-core hold --run $RUN" || true; }
cleanup() {
  cp "$RUN/holder.log" "$W/holder.log" 2>/dev/null || true # the holders' stderr, for a failed run
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  for p in $(holders); do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$RUN"
}
trap cleanup EXIT
FAKE_HOME="$W/home"
PROJ="$W/proj"
SESS="$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--"
mkdir -p "$PROJ" "$W/data" "$SESS"
printf '{"type":"session","version":3,"id":"kkkk-1","cwd":"%s"}\n' "$PROJ" > "$SESS/2026-11-01T10-00-00-000Z_kkkk-1.jsonl"

start() { # n [VAR=value...]: the app in the background (APP: its pid)
  n=$1; shift
  env "$@" HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="tests/scripts/keep-sessions-$n.txt" PI_DESK_DATA_DIR="$W/data" PI_DESK_RUNTIME_DIR="$RUN" \
    KEEP_BRIDGE_LOG="$W/bridge.log" PI_DESK_CMD="exec python3 -I '$ROOT/tests/scripts/fake-pi-keep.py' \"\$@\"" build/deckhand > "$W/run$n.log" 2>&1 &
  APP=$!
}
wait_log() { # n TEXT: until run n's log has TEXT (20 s)
  for _ in $(seq 100); do grep -q "$2" "$W/run$1.log" && return 0; sleep 0.2; done
  echo "run $1: no \"$2\" in 20 s (log: $W/run$1.log)"; exit 1
}
finish() { # n [killed]: the app ended; its log has no failure (and, unless killed, its final save)
  wait "$APP" || true
  APP=
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command|session holder" "$W/run$1.log" | sed "s/^/run $1: /" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run$1.log" || { [ "${2:-}" != killed ] && ! grep -qE "workspace save checks" "$W/run$1.log"; }; then
    echo "keep-sessions run $1 failed (log: $W/run$1.log)"; exit 1
  fi
}

# 1: keep_sessions on, 6 counting shells, quit (a handover)
start 1; finish 1
[ -n "$(holders)" ] || { echo "no session holder running after run 1"; exit 1; }
grep -q '"held":' "$W/data/workspace.json" || { echo "no held ids saved"; cat "$W/data/workspace.json"; exit 1; }
[ -f "$W/data/handover.json" ] || { echo "no handover.json"; exit 1; }

# 2: adopted exactly, the kept pi's bridge reconnects with its token; the holder restarted in
#    place (Restart session holder); then the app is killed
start 2
wait_log 2 "screen_hash"
for _ in $(seq 50); do [ "$(grep -c 'hello ok' "$W/bridge.log")" -ge 2 ] && break; sleep 0.2; done
kill -9 "$APP"
finish 2 killed
[ "$(grep -c 'hello ok' "$W/bridge.log")" -ge 2 ] || { echo "the kept pi's bridge did not reconnect after the relaunch:"; cat "$W/bridge.log"; exit 1; }
! grep -q "can't reach Deckhand" "$W/run2.log" || { echo "run 2: a kept session can't reach Deckhand (its token was not kept)"; exit 1; }
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
grep -q "holder upgraded: ok true, adopted false, holder_rev" "$W/run2.log" || { echo "run 2: Restart session holder did not upgrade it in place"; exit 1; }
[ -n "$(holders)" ] || { echo "the session holder did not outlive the app's kill -9"; exit 1; }
[ ! -f "$W/data/handover.json" ] || { echo "handover.json left after it was read"; exit 1; }

# 3: a crash restart: from the tails, inexact, the same processes; then Stop All Sessions
# PI_DESK_HOLDER_REV: the app takes its bundled holder for a newer one, so it upgrades the running
# holder by itself once the adopt is done (holder_upgrade_tick), as after an update
start 3 PI_DESK_HOLDER_REV=99; finish 3
grep -q "holder upgraded: ok true, adopted false, holder_rev" "$W/run3.log" || { echo "run 3: the older holder was not upgraded at attach"; exit 1; }
[ "$(grep -c "holder upgraded:" "$W/run3.log")" = 1 ] || { echo "run 3: more than one automatic upgrade"; exit 1; }
python3 - "$W/run3.log" "$ROOT/build/keep-sessions-before.json" "$ROOT/build/keep-sessions-crash.json" <<'PY'
import json, re, sys
log = open(sys.argv[1]).read()
adopted = re.findall(r"\[autotest\] adopted (\d+) hash \w+ (exact|inexact)", log)
fail = []
if len(adopted) != 7 or any(x != "inexact" for _, x in adopted): fail.append(f"after a crash: {adopted}, want 7 inexact")
if "holder attached: previous crash" not in log: fail.append("the holder did not say previous crash")
def tabs(p):
    return {t["title"]: t for t in json.load(open(p))["open_sessions"][0]["tabs"]}
before, after = tabs(sys.argv[2]), tabs(sys.argv[3])
for title, t in before.items():
    a = after.get(title, {})
    if a.get("pid") != t.get("pid") or not a.get("inexact") or a.get("status") != "running": fail.append(f"{title}: {a}")
if fail: sys.exit("\n".join(fail))
print("after a crash: 7 terminals adopted from the tails (inexact), same pids")
PY
# Quit and Stop All Sessions: the holder hangs up and exits (shutdown waits up to 1 s to reap)
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(holders)" ] && break; sleep 0.3; done
[ -z "$(holders)" ] || { echo "the session holder still runs after Quit and Stop All Sessions"; exit 1; }

# 4: a new holder for fresh shells, killed: every tab says the holder stopped
start 4
wait_log 4 "screen_hash"
for p in $(holders); do kill -9 "$p"; done
finish 4
grep -q "session holder lost" "$W/run4.log" || { echo "run 4: the loss was not logged"; exit 1; }
echo "keep-sessions scene ok"
