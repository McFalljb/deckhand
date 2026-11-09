#!/bin/sh
# Remote terminals (docs/plans/background-core.md §10.4 M6-C): as remote-sidebar.sh, a second core
# on this Mac (its own HOME, data and runtime dirs; DECKHAND_HUB_WITHOUT_SSHD=1, its saved
# settings let other machines in) is reached through `--via`, no ssh. That core opens a session;
# the window shows it, opens a shell there with ⌘T (forwarded with on_behalf ui), types into it and
# sees its output (the terminal relayed through this core). A window resize reaches its PTY. An
# OSC 52 from it leaves this Mac's clipboard alone. The link drops (its connect is killed, the
# other core runs on) and comes back: the shell is attached again, its screen back from a fresh
# snapshot, and typing works again. Closing the tab closes it there.
# Usage: tests/scripts/remote-terms.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/remote-terms"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkrt.XXXXXX") # this Mac's core; core.sock's path must fit in sun_path
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dkt2.XXXXXX") # the other "machine"'s
APP=
FAKE_PI='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600'
cores() { pgrep -f "deckhand-core-serve serve --run $1" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  cp "$RUN2/core.log" "$W/core2.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  pkill -9 -f "$W/via.sh" 2>/dev/null || true
  pkill -9 -f "$ROOT/build/deckhand-core-serve connect" 2>/dev/null || true
  for r in "$RUN" "$RUN2"; do
    for p in $(cores "$r"); do kill -9 "$p" 2>/dev/null || true; done
    pkill -9 -f "deckhand-core hold --run $r" 2>/dev/null || true
    rm -rf "$r"
  done
}
trap cleanup EXIT
mkdir -p "$W/data" "$W/data2" "$W/home" "$W/home2" "$W/proj2"
printf '{"v":1,"settings":{"machines_reachable":true}}\n' > "$W/data2/workspace.json"
cat > "$W/via.sh" <<VIA
#!/bin/sh
exec env HOME="$W/home2" DECKHAND_DATA_DIR="$W/data2" DECKHAND_RUNTIME_DIR="$RUN2" DECKHAND_SCRIPT=remote-terms \
  DECKHAND_HUB_WITHOUT_SSHD=1 SHELL=/bin/sh DECKHAND_CMD='$FAKE_PI' "$ROOT/build/deckhand-core-serve" connect "\$@"
VIA
chmod +x "$W/via.sh"
# the window's script ('…' keeps the shell's $((…)) for the remote shell: the screen shows the
# answer, which the typed line does not hold)
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-terms.sh's window: a shell on the other machine, worked in from here
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$W/via.sh"}
waitstate 30000 machines.0.status online
eventually 20000
assert_rows machines m2:online:1
clickid open 0
key t cmd
eventually 20000
assert_rows machines m2:online:2
waitfor $ 20000
type echo M6C-\$((6*7)) | tee relay.txt
key enter
waitfor M6C-42 20000
type stty size > size1.txt; echo SIZE1-\$((0+1))
key enter
waitfor SIZE1-1 20000
resize 1000 640
wait 500
type stty size > size2.txt; echo SIZED-\$((1+1))
key enter
waitfor SIZED-2 20000
type printf '\\033]52;c;cHduZWQ=\\007'; echo OSC-\$((5+5)) | tee osc.txt
key enter
waitfor OSC-10 20000
assert_clipboard -
waitstate 30000 machines.0.status offline
waitstate 30000 machines.0.status online
eventually 20000
assert_screen OSC-10
type echo BACK-\$((3*3))
key enter
waitfor BACK-9 20000
key w cmd
eventually 20000
assert_rows machines m2:online:1
quit_window
TXT
env HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD="$FAKE_PI" \
  build/deckhand > "$W/run.log" 2>&1 &
APP=$!
until_log() { # file pattern seconds
  i=0
  while ! grep -q "$2" "$1" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt $(($3 * 10)) ] && { echo "remote-terms: no \"$2\" in $1 within $3 s"; tail -20 "$1" 2>/dev/null; exit 1; }
    sleep 0.1
  done
}
until_file() { # path seconds
  i=0
  while [ ! -s "$1" ]; do
    i=$((i + 1)); [ $i -gt $(($2 * 10)) ] && { echo "remote-terms: no $1 within $2 s"; tail -20 "$W/run.log"; exit 1; }
    sleep 0.1
  done
}
until_log "$RUN/core.log" "machine m2: online" 30
TOK=$(sed -n "s/^export DECKHAND_SOCKET='\(.*\)' DECKHAND_TOKEN='\(.*\)'$/\2/p" "$RUN2/core.log" | tail -1)
[ -n "$TOK" ] || { echo "no control token in the other core's log"; cat "$RUN2/core.log"; exit 1; }
ctl2() { DECKHAND_SOCKET="$RUN2/core.sock" DECKHAND_TOKEN="$TOK" HOME="$W/home2" build/deckhand --ctl "$1"; }
id_of() { sed -n 's/.*"created_id":\([0-9]*\).*/\1/p'; }
# the other machine: a project and a session in it (its pi)
PID=$(ctl2 "{\"type\":\"add_project\",\"cwd\":\"$W/proj2\"}" | id_of)
[ -n "$PID" ] || { echo "add_project on the other core failed"; exit 1; }
SID=$(ctl2 "{\"type\":\"new_chat\",\"project_id\":$PID}" | id_of)
[ -n "$SID" ] || { echo "new_chat on the other core failed"; exit 1; }
# the window typed into the other machine's shell: it ran there, in its session's folder
until_file "$W/proj2/osc.txt" 60
grep -q "M6C-42" "$W/proj2/relay.txt" || { echo "remote-terms: the echo did not run on the other machine"; exit 1; }
S1=$(cat "$W/proj2/size1.txt"); S2=$(cat "$W/proj2/size2.txt")
[ -n "$S1" ] && [ "$S1" != "$S2" ] || { echo "remote-terms: the window's resize did not reach the other machine's PTY ($S1 -> $S2)"; exit 1; }
# the link drops (the other core runs on, its shell too); the next connect brings it back
pkill -f "$ROOT/build/deckhand-core-serve connect" || true
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "remote-terms: the window's script failed (log: $W/run.log)"; tail -20 "$W/run.log"; exit 1
fi
[ -s "$W/proj2/osc.txt" ] || { echo "remote-terms: no osc.txt"; exit 1; }
python3 - "$RUN/core.log" "$RUN2/core.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
seq = re.findall(r"\[autotest\] machine m2: (online|offline)", log)
want = ["online", "offline", "online"]
it = iter(seq)
if not all(any(s == w for s in it) for w in want):
    sys.exit(f"remote-terms: statuses {seq}, want {want} in order")
print(f"remote-terms: {' -> '.join(want)}; typed, resized, OSC 52 ignored, attached again, closed")
PY
echo "remote-terms: ok"
