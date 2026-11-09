#!/bin/sh
# Remote machines, the link (docs/plans/background-core.md §10.4 M6-A): a window with a separate
# core turns on Settings › Experimental › Machines over SSH and adds a machine whose link is
# `--via 'deckhand-core-serve connect'` with a data and runtime dir of its own (a second core on
# this Mac; no ssh, no sshd). connect launches that core, says the hub hello, and the machine shows
# `online` with its version. The other core asks its "window" (the hub) to set the clipboard: the
# local core drops it and the window's clipboard is untouched. Then the other core is killed (-9):
# `offline`, and `online` again once the next connect has launched it again.
# A fake HOME and temp data and runtime dirs for both cores (never the user's).
# Usage: tests/scripts/remote-link.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/remote-link"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkrl.XXXXXX") # this Mac's core; core.sock's path must fit in sun_path
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dkr2.XXXXXX") # the other "machine"'s
APP=
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
# the other machine: its own HOME, data and runtime dirs; test mode (DECKHAND_SCRIPT), so the core
# connect launches is started directly and prints a control token in its log
VIA="env HOME=$W/home2 DECKHAND_DATA_DIR=$W/data2 DECKHAND_RUNTIME_DIR=$RUN2 DECKHAND_SCRIPT=remote-link $ROOT/build/deckhand-core-serve connect"
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-link.sh's window: the link comes up, goes down when the other core dies, and comes back
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$VIA"}
waitstate 30000 machines.0.status online
waitstate 30000 machines.0.status offline
waitstate 30000 machines.0.status online
assert_clipboard -
quit_window
TXT
env HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand > "$W/run.log" 2>&1 &
APP=$!
until_log() { # file pattern seconds
  i=0
  while ! grep -q "$2" "$1" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt $(($3 * 10)) ] && { echo "remote-link: no \"$2\" in $1 within $3 s"; tail -20 "$1" 2>/dev/null; exit 1; }
    sleep 0.1
  done
}
until_log "$RUN/core.log" "machine m2: online" 30
# the other core asks its window (the hub) to set the clipboard: Copy path of a project
TOK=$(sed -n "s/^export DECKHAND_SOCKET='\(.*\)' DECKHAND_TOKEN='\(.*\)'$/\2/p" "$RUN2/core.log" | tail -1)
[ -n "$TOK" ] || { echo "no control token in the other core's log"; cat "$RUN2/core.log"; exit 1; }
ctl2() { DECKHAND_SOCKET="$RUN2/core.sock" DECKHAND_TOKEN="$TOK" HOME="$W/home2" build/deckhand --ctl "$1"; }
PID=$(ctl2 "{\"type\":\"add_project\",\"cwd\":\"$W/proj2\"}" | sed -n 's/.*"created_id":\([0-9]*\).*/\1/p')
[ -n "$PID" ] || { echo "add_project on the other core failed"; exit 1; }
ctl2 "{\"type\":\"copy_path\",\"project_id\":$PID}" > /dev/null
until_log "$RUN/core.log" "machine m2: dropped window.request" 10
# the other core dies; the next connect launches it again
OTHER=$(cores "$RUN2")
[ -n "$OTHER" ] || { echo "the other core is not running"; exit 1; }
kill -9 $OTHER
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "remote-link: the window's script failed (log: $W/run.log)"; tail -20 "$W/run.log"; exit 1
fi
python3 - "$RUN/core.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
seq = re.findall(r"\[autotest\] machine m2: (online|offline)", log)
want = ["online", "offline", "online"]
it = iter(seq)
if not all(any(s == w for s in it) for w in want):
    sys.exit(f"remote-link: statuses {seq}, want {want} in order")
if "machine m2: dropped window.request" not in log:
    sys.exit("remote-link: the clipboard request was not dropped")
print(f"remote-link: {' -> '.join(want)}; the other core's window.request dropped")
PY
[ -n "$(cores "$RUN2")" ] || { echo "the other core was not launched again"; exit 1; }
echo "remote-link: ok"
