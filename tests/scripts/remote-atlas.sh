#!/bin/sh
# The hub (docs/plans/background-core.md §10.4 M6-F): as remote-terms.sh, a second core on this Mac
# (its own HOME, data and runtime dirs; DECKHAND_HUB_WITHOUT_SSHD=1, its saved settings let other
# machines in) is reached through `--via`, no ssh. Its pi is a fake bridge
# (tests/scripts/fake-bridge-bell.py), its jobs a fake `pi --mode json`
# (tests/scripts/fake-pi-json.py). This Mac's control caller (Atlas's kind) lists that machine's
# session in get_state, under its name, and sends its pi tab a prompt: forwarded as control, it
# runs there and its status comes back through the mirror. A user-only setting sent as control on
# that machine's id is refused here first. A job there ends needing the user: this Mac's bell rings
# once, naming the machine, and its Jobs data lists the job; later states ring nothing more.
# Usage: tests/scripts/remote-atlas.sh
set -eu
unset CLAUDE_CONFIG_DIR
unset PI_KIT_NOTES_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/remote-atlas"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkra.XXXXXX") # this Mac's core; core.sock's path must fit in sun_path
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dka2.XXXXXX") # the other "machine"'s
APP=
FAKE_PI='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600'
cores() { pgrep -f "deckhand-core-serve serve --run $1" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  cp "$RUN2/core.log" "$W/core2.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  pkill -9 -f "$W/via.sh" 2>/dev/null || true
  pkill -9 -f "$ROOT/build/deckhand-core-serve connect" 2>/dev/null || true
  pkill -9 -f "$ROOT/tests/scripts/fake-bridge-bell.py" 2>/dev/null || true
  for r in "$RUN" "$RUN2"; do
    for p in $(cores "$r"); do kill -9 "$p" 2>/dev/null || true; done
    pkill -9 -f "deckhand-core hold --run $r" 2>/dev/null || true
    rm -rf "$r"
  done
}
trap cleanup EXIT
H2="$W/home2"
mkdir -p "$W/data" "$W/data2" "$W/home" "$H2/bin" "$H2/notes/jobs" "$W/proj2"
cp tests/scripts/fake-pi-json.py "$H2/bin/pi"
chmod 755 "$H2/bin/pi"
# that machine's job: it asks the user for approval (BLOCKED: needs_you)
cat > "$H2/notes/jobs/approve.md" <<'NOTE'
---
type: job
id: appr1
enabled: true
schedule: manual
notify: always
---
# Job appr1

## Prompt
BLOCKED
NOTE
printf '{"v":1,"settings":{"machines_reachable":true,"home_dir":"%s/notes","setup_seen":true,"pi_path":"%s/bin/pi"}}\n' "$H2" "$H2" > "$W/data2/workspace.json"
cat > "$W/via.sh" <<VIA
#!/bin/sh
exec env HOME="$H2" DECKHAND_DATA_DIR="$W/data2" DECKHAND_RUNTIME_DIR="$RUN2" DECKHAND_SCRIPT=remote-atlas \
  DECKHAND_HUB_WITHOUT_SSHD=1 SHELL=/bin/sh BELL_DELAY=1 \
  DECKHAND_CMD="exec python3 '$ROOT/tests/scripts/fake-bridge-bell.py' \"\\\$@\"" \
  "$ROOT/build/deckhand-core-serve" connect "\$@"
VIA
chmod +x "$W/via.sh"
# the window: the machine added, then it waits for the bell that machine's job rings here
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-atlas.sh's window
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$W/via.sh"}
waitstate 30000 machines.0.status online
waitstate 90000 notifications.count 1
wait 3000
assert_state notifications.count 1
quit_window
TXT
env HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD="$FAKE_PI" \
  build/deckhand > "$W/run.log" 2>&1 &
APP=$!
fail() { echo "remote-atlas: $*"; tail -20 "$W/run.log" 2>/dev/null; exit 1; }
until_log() { # file pattern seconds
  i=0
  while ! grep -q "$2" "$1" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt $(($3 * 10)) ] && { tail -20 "$1" 2>/dev/null; fail "no \"$2\" in $1 within $3 s"; }
    sleep 0.1
  done
}
token_of() { sed -n "s/^export DECKHAND_SOCKET='\(.*\)' DECKHAND_TOKEN='\(.*\)'$/\2/p" "$1" | tail -1; }
until_log "$RUN/core.log" "machine m2: online" 30
TOK=$(token_of "$RUN/core.log") # this Mac's core: a control token (Atlas's kind)
TOK2=$(token_of "$RUN2/core.log")
[ -n "$TOK" ] && [ -n "$TOK2" ] || fail "no control tokens in the cores' logs"
ctl() { DECKHAND_SOCKET="$RUN/core.sock" DECKHAND_TOKEN="$TOK" HOME="$W/home" build/deckhand --ctl "$1"; }
ctl2() { DECKHAND_SOCKET="$RUN2/core.sock" DECKHAND_TOKEN="$TOK2" HOME="$H2" build/deckhand --ctl "$1"; }
id_of() { sed -n 's/.*"created_id":\([0-9]*\).*/\1/p'; }
# the other machine: a project and a pi session in it
PID=$(ctl2 "{\"type\":\"add_project\",\"cwd\":\"$W/proj2\"}" | id_of)
[ -n "$PID" ] || fail "add_project on the other core failed"
SID=$(ctl2 "{\"type\":\"new_chat\",\"project_id\":$PID}" | id_of)
[ -n "$SID" ] || fail "new_chat on the other core failed"
ctl2 "{\"type\":\"focus_session\",\"session\":$SID}" > /dev/null # its pi starts there (its fake bridge reports idle)
# this Mac's control caller sees it in get_state, under its name, and prompts its pi tab there
cat > "$W/check.py" <<'PY'
import json, subprocess, sys, time
ctl, want, deadline = sys.argv[1], sys.argv[2], time.time() + float(sys.argv[3])
def state():
    out = subprocess.run(["sh", "-c", ctl + " '{\"type\":\"get_state\"}'"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        d = (m.get("result") or {}).get("data")
        if isinstance(d, str): d = json.loads(d)
        if isinstance(d, dict): return d
    return {}
while True:
    st = state()
    tabs = [t for s in st.get("open_sessions", []) if s.get("machine") == "m2" for t in s.get("tabs", []) if t.get("kind") == "pi"]
    if want == "tab" and tabs and tabs[0].get("machine") == "m2" and tabs[0].get("agent") == "idle":
        print(tabs[0]["id"]); sys.exit(0)
    if want == "working" and tabs and tabs[0].get("agent") == "working":
        sys.exit(0)
    if want == "job":
        jobs = [j for j in st.get("machine_jobs", []) if j.get("machine") == "m2" and j.get("id", "").endswith(":appr1")]
        if jobs and jobs[0].get("needs_you"):
            print(json.dumps(jobs[0])); sys.exit(0)
    if time.time() > deadline:
        sys.exit("remote-atlas: get_state never showed %s: %s" % (want, json.dumps(tabs)[:600]))
    time.sleep(0.3)
PY
CTL="DECKHAND_SOCKET='$RUN/core.sock' DECKHAND_TOKEN='$TOK' HOME='$W/home' build/deckhand --ctl"
TAB=$(python3 -I "$W/check.py" "$CTL" tab 30) || fail "the other machine's pi tab is not in this Mac's get_state"
OUT=$(ctl "{\"type\":\"pi_prompt\",\"tab_id\":$TAB,\"text\":\"working\"}" || true)
case "$OUT" in *'"finished"'*'"ok":true'*) ;; *) fail "pi_prompt as control on the other machine's tab: $OUT" ;; esac
python3 -I "$W/check.py" "$CTL" working 30 || fail "the prompt did not reach the other machine's pi"
grep -q "machine m2: forwarded pi_prompt" "$RUN/core.log" || fail "the prompt was not forwarded"
# control's rules here first: a user-only setting is refused, never forwarded
OUT=$(ctl '{"type":"set_remote_machines","on":false}' || true)
case "$OUT" in *"not allowed"*) ;; *) fail "a user-only setting from control was not refused: $OUT" ;; esac
# a job there needs the user: this Mac's bell rings, once, naming it
OUT=$(ctl2 '{"type":"job_run_now","job":"appr1"}' || true)
case "$OUT" in *'"ok":true'*) ;; *) fail "job_run_now on the other core: $OUT" ;; esac
until_log "$RUN/core.log" "machine m2: rang job_needs_you m2 · " 60
python3 -I "$W/check.py" "$CTL" job 30 > /dev/null || fail "machine_jobs has no job that needs the user"
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  fail "the window's script failed (log: $W/run.log)"
fi
N=$(grep -c "machine m2: rang " "$RUN/core.log" || true)
[ "$N" = 1 ] || fail "the bell rang $N times, want once"
echo "remote-atlas: listed, prompted as control, user-only refused, job rang once: ok"
