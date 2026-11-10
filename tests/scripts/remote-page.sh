#!/bin/sh
# A machine's web page in a local tab (issue #5; src/core/machine_page.odin): as remote-link.sh, a
# second core on this Mac is reached through `--via` (no ssh, no sshd: DECKHAND_HUB_WITHOUT_SSHD=1).
# A via machine is this Mac, so its "forward" is the port itself: this checks the command (user
# only, its checks), the tab it opens (a plain local browser tab at http://127.0.0.1:<port>/<path>,
# from the command and from the sidebar's Open web page… through the palette) and the forward
# table (each tab's entry goes when it closes). Not covered without real ssh: `ssh -O forward` and
# `-O cancel` on a ControlMaster (their argv is unit-tested: machine_page_test.odin). Test mode's
# Chromium is offline (a dead proxy, loopback too), so the page itself is not loaded.
# Usage: tests/scripts/remote-page.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/remote-page"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkrp.XXXXXX") # this Mac's core; core.sock's path must fit in sun_path
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dkp2.XXXXXX") # the other "machine"'s
APP=
cores() { pgrep -f "deckhand-core-serve serve --run $1" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  pkill -9 -f "$ROOT/build/deckhand-core-serve connect" 2>/dev/null || true
  for r in "$RUN" "$RUN2"; do
    for p in $(cores "$r"); do kill -9 "$p" 2>/dev/null || true; done
    pkill -9 -f "deckhand-core hold --run $r" 2>/dev/null || true
    rm -rf "$r"
  done
}
trap cleanup EXIT
mkdir -p "$W/data" "$W/data2" "$W/home" "$W/home2" "$W/proj"
printf '{"v":1,"settings":{"machines_reachable":true}}\n' > "$W/data2/workspace.json"
VIA="env HOME=$W/home2 DECKHAND_DATA_DIR=$W/data2 DECKHAND_RUNTIME_DIR=$RUN2 DECKHAND_SCRIPT=remote-page DECKHAND_HUB_WITHOUT_SSHD=1 $ROOT/build/deckhand-core-serve connect"
P=48123
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-page.sh's window: a web page of machine m2's in a tab of this Mac's session
waitstate 20000 open_sessions.# 1
ui_command {"type":"machine_open_page","no":1,"port":$P}
assert_result ok false
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$VIA"}
waitstate 30000 machines.0.status online
# the user's only; a port 1-65535; a path, never a host
control_command {"type":"machine_open_page","no":1,"port":$P}
assert_result ok false
command {"type":"machine_open_page","no":1,"port":$P}
assert_result ok false
ui_command {"type":"machine_open_page","no":1,"port":0}
assert_result ok false
ui_command {"type":"machine_open_page","no":1,"port":$P,"path":"//evil.example/"}
assert_result ok false
ui_command {"type":"machine_open_page","no":1,"port":$P,"path":"hello?x=1"}
assert_result ok true
eventually 10000
assert_state open_sessions.0.tabs.1.kind browser
assert_state open_sessions.0.tabs.1.url http://127.0.0.1:$P/hello?x=1
ui_command {"type":"close_tab","tab_id":\$last}
eventually 10000
assert_state open_sessions.0.tabs.# 1
# the sidebar's button: the palette asks for the port
clickid machact 1
wait 300
type $P/docs
key enter
eventually 10000
assert_state open_sessions.0.tabs.1.url http://127.0.0.1:$P/docs
quit_window
TXT
env HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand "$W/proj" > "$W/run.log" 2>&1 &
APP=$!
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "remote-page: the window's script failed (log: $W/run.log)"; tail -20 "$W/run.log"; exit 1
fi
LOG="$RUN/core.log"
n=$(grep -c "\[autotest\] page forward $P: m2 port $P" "$LOG" || true)
[ "$n" = 2 ] || { echo "remote-page: want 2 forwards opened, got $n"; grep "page forward" "$LOG"; exit 1; }
grep -q "\[autotest\] page forward $P closed: its tab closed" "$LOG" || { echo "remote-page: the closed tab's forward did not go"; grep "page forward" "$LOG"; exit 1; }
echo "remote-page: ok"
