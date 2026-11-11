#!/bin/sh
# Remote machines in the sidebar (docs/plans/background-core.md §10.4 M6-B): as remote-link.sh, a
# second core on this Mac (its own HOME, data and runtime dirs; DECKHAND_HUB_WITHOUT_SSHD=1, its
# saved settings let other machines in) is reached through `--via`, no ssh. That core opens a
# session with two shells; the window lists it under the machine's name, and showing it runs
# nothing here (its shell's terminal is relayed from that core, M6-C). The link then drops (its
# connect is killed, the other core runs on): the machine is offline, its session still listed (greyed). The next connect brings it back online,
# from a fresh state.full.
# Usage: tests/scripts/remote-sidebar.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/remote-sidebar"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkrs.XXXXXX") # this Mac's core; core.sock's path must fit in sun_path
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dks2.XXXXXX") # the other "machine"'s
APP=
FAKE_PI='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600'
cores() { pgrep -f "deckhand-core-serve serve --run $1" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  cp "$RUN2/core.log" "$W/core2.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
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
# the via command: one word per argument (machines.odin splits it), so the other core's settings
# (a fake pi among them) are in a script
cat > "$W/via.sh" <<VIA
#!/bin/sh
exec env HOME="$W/home2" DECKHAND_DATA_DIR="$W/data2" DECKHAND_RUNTIME_DIR="$RUN2" DECKHAND_SCRIPT=remote-sidebar \
  DECKHAND_HUB_WITHOUT_SSHD=1 SHELL=/bin/sh DECKHAND_CMD='$FAKE_PI' "$ROOT/build/deckhand-core-serve" connect "\$@"
VIA
chmod +x "$W/via.sh"
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-sidebar.sh's window: the other machine's session under its name, offline and back
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$W/via.sh"}
waitstate 30000 machines.0.status online
eventually 20000
assert_rows machines m2:online:3
assert_drawn m2
assert_not_drawn M2
assert_drawn Add a machine…
rclickid machhead 1
assert_menurows Open web page…|-|Rename…|Remove…
key escape
ui_command {"type":"set_left_tab","tab":"settings"}
wait 500
assert_drawn Machines
assert_not_drawn experimental
assert_not_drawn via ·
ui_command {"type":"set_left_tab","tab":"sessions"}
wait 300
assert_rows open -
clickid open 0
waitfor $ 20000
eventually 20000
assert_rows machines m2:offline:3
assert_drawn offline
eventually 20000
assert_rows machines m2:online:3
assert_clipboard -
quit_window
TXT
env HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD="$FAKE_PI" \
  build/deckhand > "$W/run.log" 2>&1 &
APP=$!
until_log() { # file pattern seconds
  i=0
  while ! grep -q "$2" "$1" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt $(($3 * 10)) ] && { echo "remote-sidebar: no \"$2\" in $1 within $3 s"; tail -20 "$1" 2>/dev/null; exit 1; }
    sleep 0.1
  done
}
until_log "$RUN/core.log" "machine m2: online" 30
TOK=$(sed -n "s/^export DECKHAND_SOCKET='\(.*\)' DECKHAND_TOKEN='\(.*\)'$/\2/p" "$RUN2/core.log" | tail -1)
[ -n "$TOK" ] || { echo "no control token in the other core's log"; cat "$RUN2/core.log"; exit 1; }
ctl2() { DECKHAND_SOCKET="$RUN2/core.sock" DECKHAND_TOKEN="$TOK" HOME="$W/home2" build/deckhand --ctl "$1"; }
id_of() { sed -n 's/.*"created_id":\([0-9]*\).*/\1/p'; }
# the other machine: a project, a session in it (its pi), two shells
PID=$(ctl2 "{\"type\":\"add_project\",\"cwd\":\"$W/proj2\"}" | id_of)
[ -n "$PID" ] || { echo "add_project on the other core failed"; exit 1; }
SID=$(ctl2 "{\"type\":\"new_chat\",\"project_id\":$PID}" | id_of)
[ -n "$SID" ] || { echo "new_chat on the other core failed"; exit 1; }
ctl2 "{\"type\":\"new_shell_tab\",\"session\":$SID}" | grep -q '"ok":true' || { echo "new_shell_tab failed"; exit 1; }
ctl2 "{\"type\":\"new_shell_tab\",\"session\":$SID}" | grep -q '"ok":true' || { echo "new_shell_tab failed"; exit 1; }
until_log "$W/run.log" "found \\$" 30
# the link drops (the other core runs on): offline, then the next connect brings it back
pkill -f "$ROOT/build/deckhand-core-serve connect" || true
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "remote-sidebar: the window's script failed (log: $W/run.log)"; tail -20 "$W/run.log"; exit 1
fi
# nothing of the other machine's was saved here
if grep -q "proj2" "$W/data/workspace.json" 2>/dev/null; then echo "remote-sidebar: the other machine's project was saved here"; exit 1; fi
python3 - "$RUN/core.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
seq = re.findall(r"\[autotest\] machine m2: (online|offline)", log)
want = ["online", "offline", "online"]
it = iter(seq)
if not all(any(s == w for s in it) for w in want):
    sys.exit(f"remote-sidebar: statuses {seq}, want {want} in order")
print(f"remote-sidebar: {' -> '.join(want)}; its session listed throughout")
PY
echo "remote-sidebar: ok"
