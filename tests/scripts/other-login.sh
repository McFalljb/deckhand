#!/bin/sh
# A core and a session holder from another login (#202; src/core/login_session.odin), with a
# separate core and keep_sessions on. DECKHAND_TEST_ASID stands in for the audit session (the
# login) a process runs in:
# 1. a window under login 111 starts a core and a holder (both noted as 111), and a session whose
#    fake pi ticks. The scene kills the window (-9): the core and the holder run on, as after a
#    logout.
# 2. a window under login 222 finds that core: it stops it (SIGTERM, its save) instead of
#    attaching, and launches a core of its own. That core finds the old holder (111) and replaces
#    it too. The session restores: a new fake pi (another pid), and both toasts.
# A fake HOME, a fake pi, a temp data dir and a short runtime dir (never the user's). Every
# process it signals is its own, by pid.
# Usage: tests/scripts/other-login.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/other-login"
rm -rf "$W" "$ROOT"/build/other-login-[12].txt
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkol.XXXXXX") # core.sock's path must fit in sun_path
APP=
cores() { pgrep -f "deckhand-core-serve serve --run $RUN" || true; }
holders() { pgrep -f "deckhand-core hold --run $RUN" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  cp "$RUN/holder.log" "$W/holder.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  for p in $(cores) $(holders) $(pgrep -f "other-login-pi $RUN" || true); do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$RUN"
}
trap cleanup EXIT
FAKE_HOME="$W/home"
PROJ="$W/proj"
SESS="$FAKE_HOME/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--"
mkdir -p "$PROJ" "$W/data" "$SESS"
printf '{"type":"session","version":3,"id":"oooo-1","cwd":"%s"}\n' "$PROJ" > "$SESS/2026-11-01T10-00-00-000Z_oooo-1.jsonl"
start() { # n asid: a window in the background (APP: its pid)
  env HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="tests/scripts/other-login-$1.txt" \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_TEST_ASID="$2" \
    DECKHAND_CMD="while [ \"\${1:-}\" = -e ]; do shift 2; done; echo ARGS: pi; exec sh -c 'i=0; while :; do i=\$((i+1)); echo turn-tick \$i pid \$\$; sleep 0.2; done' other-login-pi $RUN" \
    build/deckhand > "$W/run$1.log" 2>&1 &
  APP=$!
}
wait_for() { # FILE TEXT SECONDS
  for _ in $(seq $(($3 * 10))); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done
  echo "no \"$2\" in $1 within $3 s"; tail -20 "$1" 2>/dev/null; exit 1
}
failed() { grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run$1.log"; }
gone() { ! kill -0 "$1" 2>/dev/null; }

start 1 111
wait_for "$W/run1.log" "core: attached to pid" 20
CORE=$(cores)
wait_for "$ROOT/build/other-login-1.txt" "turn-tick" 20
HOLDER=$(holders)
[ -n "$CORE" ] && [ -n "$HOLDER" ] || { echo "no core ($CORE) or holder ($HOLDER)"; exit 1; }
! failed 1 || { echo "run 1 failed"; tail -20 "$W/run1.log"; exit 1; }
kill -9 "$APP"; wait "$APP" 2>/dev/null || true; APP=
sleep 1
[ "$(cores)" = "$CORE" ] && [ "$(holders)" = "$HOLDER" ] || { echo "the core and holder did not run on ($CORE $HOLDER -> $(cores) $(holders))"; exit 1; }

start 2 222
wait_for "$W/run2.log" "core: replacing pid $CORE from another login" 20
wait_for "$W/run2.log" "core: attached to pid" 40
wait_for "$W/run2.log" "toast:.*Replaced Deckhand's core from an earlier login" 20
wait_for "$RUN/core.log" "holder: replaced one from another login (pid $HOLDER" 20
wait_for "$W/run2.log" "toast:.*session holder was from an earlier login" 20
wait_for "$ROOT/build/other-login-2.txt" "turn-tick" 30
wait "$APP" || true; APP=
if failed 2 || ! grep -q "done:" "$W/run2.log"; then echo "run 2 failed (log: $W/run2.log)"; tail -20 "$W/run2.log"; exit 1; fi
gone "$CORE" || { echo "the old core $CORE still runs"; exit 1; }
gone "$HOLDER" || { echo "the old holder $HOLDER still runs"; exit 1; }
NEW=$(cores); NEWH=$(holders)
[ -n "$NEW" ] && [ "$NEW" != "$CORE" ] && [ -n "$NEWH" ] && [ "$NEWH" != "$HOLDER" ] || { echo "no new core and holder ($NEW $NEWH)"; exit 1; }
grep -q "^222$" "$RUN/test-asid-$NEW" && grep -q "^222$" "$RUN/test-asid-$NEWH" || { echo "the new core or holder is not in login 222"; exit 1; }
python3 - "$ROOT/build/other-login-1.txt" "$ROOT/build/other-login-2.txt" <<'PY'
import re, sys
pids = [sorted(set(re.findall(r"turn-tick \d+ pid (\d+)", open(p).read()))) for p in sys.argv[1:]]
if len(pids[0]) != 1 or len(pids[1]) < 1 or pids[1][-1] == pids[0][0]:
    sys.exit(f"the session did not restart in the new login: pi pids {pids}")
print(f"pi {pids[0][0]} in login 111, replaced; pi {pids[1][-1]} restored in login 222")
PY
kill -TERM "$NEW"
for _ in $(seq 100); do [ -z "$(cores)" ] && break; sleep 0.1; done
[ -z "$(cores)" ] || { echo "the core did not stop on SIGTERM"; exit 1; }
echo "other-login: ok"
