#!/bin/sh
# Install and one-click update of another machine's core (docs/plans/background-core.md §10.4
# M6-E), as remote-sidebar.sh: a second core on this Mac (its own HOME, data and runtime dirs;
# DECKHAND_HUB_WITHOUT_SSHD=1) reached through `--via`, no ssh. Its "ssh" for the install is
# DECKHAND_TEST_SSH (a /bin/sh stand-in that runs the remote command with that HOME), and its data
# dir is the one the install script writes ($HOME/Library/Application Support/Deckhand).
#   1. The machine is added with nothing installed: its connect finds no core (127), the install
#      starts by itself, copies this Mac's core/current Deckhand Core.app (a bundle laid out and
#      signed here from build/'s binaries, installed into this Mac's data dir first), runs its
#      `install`, and the machine comes up online.
#   2. Its core is made an older one (DECKHAND_TEST_CORE_VERSION=0.1.0, below CORE_MIN: needs_update)
#      with a session of two shells. Update (machine_install) copies again, its old core gets
#      core_handover on the link, and the new core comes up: the shells' pids are the same, and
#      each terminal's screen hash at the handover is the one the new core adopted.
# Usage: tests/scripts/remote-install.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
. scripts/sign.sh
W="$ROOT/build/remote-install"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkri.XXXXXX") # this Mac's core
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dki2.XXXXXX") # the other "machine"'s
APP=
FAKE_PI='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600'
H2="$W/home2"
D2="$H2/Library/Application Support/Deckhand"
cores() { pgrep -f "serve --run $1" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  cp "$RUN2/core.log" "$W/core2.log" 2>/dev/null || true
  [ -n "$APP" ] && kill -9 "$APP" 2>/dev/null || true
  pkill -9 -f "deckhand-core-serve connect --from" 2>/dev/null || true
  for r in "$RUN" "$RUN2"; do
    for p in $(cores "$r"); do kill -9 "$p" 2>/dev/null || true; done
    pkill -9 -f "deckhand-core hold --run $r" 2>/dev/null || true
    rm -rf "$r"
  done
}
trap cleanup EXIT
mkdir -p "$W/data" "$D2" "$W/home" "$W/proj2"
printf '{"v":1,"settings":{"machines_reachable":true}}\n' > "$D2/workspace.json"

# this Mac's Deckhand Core.app, as scripts/bundle-app.sh lays it out (a scene has no CEF build),
# signed as build.sh signs, then installed: core/current is what the install copies
sign_resolve
CA="$W/src/Deckhand Core.app"
mkdir -p "$CA/Contents/MacOS"
cat > "$CA/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>deckhand-core</string>
<key>CFBundleIdentifier</key><string>dev.deckhand.core</string>
<key>CFBundleName</key><string>Deckhand Core</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PL
cp build/deckhand-core build/deckhand-core-serve "$CA/Contents/MacOS/"
sign_code --identifier dev.deckhand.core "$CA/Contents/MacOS/deckhand-core-serve"
sign_code "$CA"
"$CA/Contents/MacOS/deckhand-core-serve" install --data "$W/data" > /dev/null
INSTALLED="$D2/core/current/Deckhand Core.app/Contents/MacOS/deckhand-core-serve"

# the via command: the installed core's connect there (none yet: exit 127, not_installed); the
# file "old" makes the core it launches an older one
cat > "$W/via.sh" <<VIA
#!/bin/sh
[ -f "$W/old" ] && export DECKHAND_TEST_CORE_VERSION=0.1.0
exec env HOME="$H2" DECKHAND_DATA_DIR="$D2" DECKHAND_RUNTIME_DIR="$RUN2" DECKHAND_SCRIPT=remote-install \
  DECKHAND_HUB_WITHOUT_SSHD=1 SHELL=/bin/sh DECKHAND_CMD='$FAKE_PI' "$INSTALLED" connect "\$@"
VIA
# the install's ssh: the remote command run by /bin/sh with that machine's HOME
cat > "$W/ssh.sh" <<SSH
#!/bin/sh
exec env HOME="$H2" /bin/sh -c "\$1"
SSH
chmod +x "$W/via.sh" "$W/ssh.sh"
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-install.sh's window: install, then Update
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$W/via.sh"}
waitstate 60000 machines.0.job done
waitstate 30000 machines.0.status online
waitstate 120000 machines.0.update button
ui_command {"type":"machine_install","no":1}
waitstate 120000 machines.0.job done
waitstate 30000 machines.0.status online
quit_window
TXT
env HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD="$FAKE_PI" DECKHAND_TEST_SSH="$W/ssh.sh" \
  build/deckhand > "$W/run.log" 2>&1 &
APP=$!
until_log() { # file pattern seconds
  i=0
  while ! grep -q "$2" "$1" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt $(($3 * 10)) ] && { echo "remote-install: no \"$2\" in $1 within $3 s"; tail -20 "$1" 2>/dev/null; exit 1; }
    sleep 0.1
  done
}
# 1. installed by itself, then online
until_log "$RUN/core.log" "machine m2 install: installed" 60
until_log "$RUN/core.log" "machine m2: online" 30
[ -x "$INSTALLED" ] || { echo "remote-install: nothing installed at $INSTALLED"; exit 1; }
ls -d "$D2"/core/.incoming-* 2>/dev/null && { echo "remote-install: a staging dir was left"; exit 1; }
# 2. its core, an older one, with a session of two shells
TOK=$(sed -n "s/^export DECKHAND_SOCKET='\(.*\)' DECKHAND_TOKEN='\(.*\)'$/\2/p" "$RUN2/core.log" | tail -1)
[ -n "$TOK" ] || { echo "no control token in the other core's log"; cat "$RUN2/core.log"; exit 1; }
ctl2() { DECKHAND_SOCKET="$RUN2/core.sock" DECKHAND_TOKEN="$TOK" HOME="$H2" build/deckhand --ctl "$1"; }
id_of() { sed -n 's/.*"created_id":\([0-9]*\).*/\1/p'; }
PID=$(ctl2 "{\"type\":\"add_project\",\"cwd\":\"$W/proj2\"}" | id_of)
SID=$(ctl2 "{\"type\":\"new_chat\",\"project_id\":$PID}" | id_of)
[ -n "$SID" ] || { echo "new_chat on the other core failed"; exit 1; }
ctl2 "{\"type\":\"new_shell_tab\",\"session\":$SID}" | grep -q '"ok":true' || { echo "new_shell_tab failed"; exit 1; }
ctl2 "{\"type\":\"new_shell_tab\",\"session\":$SID}" | grep -q '"ok":true' || { echo "new_shell_tab failed"; exit 1; }
HOLDER=$(pgrep -f "deckhand-core hold --run $RUN2" | head -1)
[ -n "$HOLDER" ] || { echo "remote-install: no session holder there"; exit 1; }
sleep 1
KIDS1=$(pgrep -P "$HOLDER" | sort | tr '\n' ' ')
[ "$(echo $KIDS1 | wc -w)" -ge 3 ] || { echo "remote-install: the holder runs $KIDS1"; exit 1; }
touch "$W/old"
for p in $(cores "$RUN2"); do kill "$p"; done # its sessions stay in the holder; connect starts the old one
until_log "$RUN/core.log" "machine m2: needs_update" 60
until_log "$RUN/core.log" "machine m2 install: core_handover sent" 120
until_log "$RUN/core.log" "machine m2 install: installed" 120
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "remote-install: the window's script failed (log: $W/run.log)"; tail -20 "$W/run.log"; exit 1
fi
KIDS2=$(pgrep -P "$HOLDER" | sort | tr '\n' ' ')
[ "$KIDS1" = "$KIDS2" ] || { echo "remote-install: the sessions' processes changed: $KIDS1 -> $KIDS2"; exit 1; }
python3 -I - "$RUN2/core.log" <<'PY'
import re, sys
log = open(sys.argv[1]).read()
given = dict(re.findall(r"\[autotest\] handover (\d+) offset \d+ hash (\w+)", log))
took = dict(re.findall(r"\[autotest\] adopted (\d+) hash (\w+) exact", log))
if len(given) < 2:
    sys.exit(f"remote-install: {len(given)} terminals handed over, want 2")
bad = [t for t in given if took.get(t) != given[t]]
if bad:
    sys.exit(f"remote-install: screen hashes differ across the handover for {bad}: {given} vs {took}")
print(f"remote-install: {len(given)} terminals handed over exactly")
PY
echo "remote-install: ok"
