#!/bin/sh
# Add a folder on another machine (#135): as remote-terms.sh, a second core on this Mac (its own
# HOME, data and runtime dirs; DECKHAND_HUB_WITHOUT_SSHD=1, its saved settings let other machines
# in) is reached through `--via`, no ssh. That machine is fresh: no project, no pi, no Claude Code
# (test mode finds neither under its HOME, and it has no stand-in). The window adds a folder of it
# by the empty machine's "Add folder on m2…" row (the palette asks for a path, ~/… there): a missing
# one is refused with that core's words; an existing one becomes that core's project (on its disk,
# never this Mac's) and shows here. Its New session opens a session there all the same (its pi tab
# says pi is missing), and ⌘T beside it is a terminal on that machine: typed into, it runs there.
# Usage: tests/scripts/remote-folder.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/remote-folder"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkrf.XXXXXX") # this Mac's core; core.sock's path must fit in sun_path
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dkf2.XXXXXX") # the other "machine"'s
APP=
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
H2="$W/home2"
mkdir -p "$W/data" "$W/data2" "$W/home" "$H2/app"
printf '{"v":1,"settings":{"machines_reachable":true,"setup_seen":true}}\n' > "$W/data2/workspace.json"
# that machine: no DECKHAND_CMD or DECKHAND_CLAUDE_CMD (test mode runs neither the real pi nor claude)
cat > "$W/via.sh" <<VIA
#!/bin/sh
exec env HOME="$H2" DECKHAND_DATA_DIR="$W/data2" DECKHAND_RUNTIME_DIR="$RUN2" DECKHAND_SCRIPT=remote-folder \
  DECKHAND_HUB_WITHOUT_SSHD=1 SHELL=/bin/sh "$ROOT/build/deckhand-core-serve" connect "\$@"
VIA
chmod +x "$W/via.sh"
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-folder.sh's window
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$W/via.sh"}
waitstate 30000 machines.0.status online
# a folder that is not there: that core says so, nothing is added
clickid machfolder 1
wait 300
type ~/nope
key enter
eventually 20000
assert_toast no such folder
assert_rows tree -
# the folder: that core's project, shown and selected here
clickid machfolder 1
wait 300
type ~/app
key enter
eventually 20000
assert_rows tree ~/app
# no agent there: New session opens one all the same, and ⌘T is a terminal there
clickid new
eventually 20000
assert_rows machines m2:online:1
key t cmd
eventually 20000
assert_rows machines m2:online:2
waitfor $ 20000
type echo FOLDER-\$((6*7)) | tee there.txt
key enter
waitfor FOLDER-42 20000
quit_window
TXT
env HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
  build/deckhand > "$W/run.log" 2>&1 &
APP=$!
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "remote-folder: the window's script failed (log: $W/run.log)"; tail -20 "$W/run.log"; exit 1
fi
# the shell ran there, in that folder; the project is that core's, never this Mac's
grep -q "FOLDER-42" "$H2/app/there.txt" 2>/dev/null || { echo "remote-folder: the terminal did not run in that machine's folder"; exit 1; }
i=0
until grep -q "$H2/app" "$W/data2/workspace.json" 2>/dev/null; do # saved there (after its save delay)
  i=$((i + 1)); [ $i -gt 100 ] && { echo "remote-folder: that core did not keep the project"; exit 1; }
  sleep 0.1
done
if grep -q "home2/app" "$W/data/workspace.json" 2>/dev/null; then echo "remote-folder: this Mac saved that machine's folder"; exit 1; fi
grep -q "machine m2: forwarded add_project" "$RUN/core.log" || { echo "remote-folder: add_project was not forwarded"; exit 1; }
echo "remote-folder: a missing folder refused there, a folder added there, a session and a terminal there without an agent: ok"
