#!/bin/sh
# Codex tabs on another machine (docs/CODEX.md "On another machine"): as remote-atlas.sh, a second
# core on this Mac (its own HOME, data and runtime dirs; DECKHAND_HUB_WITHOUT_SSHD=1, its saved
# settings let other machines in) is reached through `--via`, no ssh. Its codex is a stand-in (a
# shell script that records its argv and environment; never a real codex). That core's hello says
# codex_tabs; this Mac's control caller starts a Codex session in that machine's project: forwarded,
# it runs there with that core's own hooks, MCP server, socket and token (never this Mac's), and
# this Mac's get_state lists its tab as a Codex tab of that machine.
# Usage: tests/scripts/remote-codex.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/remote-codex"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkrc.XXXXXX") # this Mac's core; core.sock's path must fit in sun_path
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dkc2.XXXXXX") # the other "machine"'s
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
H2="$W/home2"
mkdir -p "$W/data" "$W/data2" "$W/home" "$H2" "$W/proj2"
# that machine's Codex "installed" by npm (a stand-in package, never run; its version from its
# package.json), and the stand-in its tabs run
pkg="$H2/npm/lib/node_modules/@openai/codex"
mkdir -p "$pkg/bin" "$H2/npm/bin"
printf '{"name":"@openai/codex","version":"0.167.2"}\n' > "$pkg/package.json"
printf '#!/bin/sh\nexit 1\n' > "$pkg/bin/codex.js"
chmod 755 "$pkg/bin/codex.js"
ln -sf "$pkg/bin/codex.js" "$H2/npm/bin/codex"
cat > "$W/fake-codex.sh" <<FAKE
#!/bin/sh
[ "\${1:-}" = login ] && exit 0 # codex login status: signed in
printf '%s\n' "\$@" > "$W/argv.txt"
printf 'SOCKET=%s\nTOKEN=%s\n' "\$DECKHAND_SOCKET" "\${DECKHAND_CLAUDE_TOKEN:+set}" > "$W/env.txt"
echo CODEX-STAND-IN
exec sleep 600
FAKE
chmod 755 "$W/fake-codex.sh"
printf '{"v":1,"settings":{"machines_reachable":true,"setup_seen":true}}\n' > "$W/data2/workspace.json"
cat > "$W/via.sh" <<VIA
#!/bin/sh
exec env HOME="$H2" DECKHAND_DATA_DIR="$W/data2" DECKHAND_RUNTIME_DIR="$RUN2" DECKHAND_SCRIPT=remote-codex \
  DECKHAND_HUB_WITHOUT_SSHD=1 SHELL=/bin/sh DECKHAND_CMD='$FAKE_PI' \
  DECKHAND_CODEX_BIN="$H2/npm/bin/codex" DECKHAND_CODEX_CMD="exec '$W/fake-codex.sh' \"\\\$@\"" \
  "$ROOT/build/deckhand-core-serve" connect "\$@"
VIA
chmod +x "$W/via.sh"
# the window: the machine added; it quits once the link drops (the end of the checks below)
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-codex.sh's window
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$W/via.sh"}
waitstate 30000 machines.0.status online
waitstate 90000 machines.0.status offline
quit_window
TXT
env HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD="$FAKE_PI" \
  build/deckhand > "$W/run.log" 2>&1 &
APP=$!
fail() { echo "remote-codex: $*"; tail -20 "$W/run.log" 2>/dev/null; exit 1; }
until_log() { # file pattern seconds
  i=0
  while ! grep -q "$2" "$1" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt $(($3 * 10)) ] && { tail -20 "$1" 2>/dev/null; fail "no \"$2\" in $1 within $3 s"; }
    sleep 0.1
  done
}
until_file() { # path seconds
  i=0
  while [ ! -s "$1" ]; do
    i=$((i + 1)); [ $i -gt $(($2 * 10)) ] && fail "no $1 within $2 s"
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
PID=$(ctl2 "{\"type\":\"add_project\",\"cwd\":\"$W/proj2\"}" | id_of)
[ -n "$PID" ] || fail "add_project on the other core failed"
# this Mac's view: that project's packed id, then its Codex tab
cat > "$W/check.py" <<'PY'
import json, subprocess, sys, time
ctl, want, deadline = sys.argv[1], sys.argv[2], time.time() + 30
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
    if want == "project":
        ps = [p for p in st.get("projects", []) if p.get("machine") == "m2" and p.get("cwd", "").endswith("/proj2")]
        if ps:
            print(ps[0]["id"]); sys.exit(0)
    if want == "tab":
        tabs = [t for s in st.get("open_sessions", []) if s.get("machine") == "m2" for t in s.get("tabs", []) if t.get("kind") == "claude"]
        if tabs and tabs[0].get("harness") == "codex" and tabs[0].get("machine") == "m2":
            sys.exit(0)
    if time.time() > deadline:
        sys.exit("remote-codex: get_state never showed the %s" % want)
    time.sleep(0.3)
PY
CTL="DECKHAND_SOCKET='$RUN/core.sock' DECKHAND_TOKEN='$TOK' HOME='$W/home' build/deckhand --ctl"
RPID=$(python3 -I "$W/check.py" "$CTL" project) || fail "that machine's project is not in this Mac's get_state"
OUT=$(ctl "{\"type\":\"new_claude_session\",\"project_id\":$RPID,\"harness\":\"codex\"}" || true)
case "$OUT" in *'"finished"'*'"ok":true'*) ;; *) fail "new_claude_session harness codex on the other machine's project: $OUT" ;; esac
grep -q "machine m2: forwarded new_claude_session" "$RUN/core.log" || fail "the start was not forwarded"
# it ran there: that core's hooks and tools (its CLI), its socket and a token of its own
until_file "$W/env.txt" 30
head -3 "$W/argv.txt" | tr '\n' ' ' | grep -q "^--no-daemon -C $W/proj2 " || fail "codex's argv there: $(head -3 "$W/argv.txt")"
grep -q "hooks.state=" "$W/argv.txt" && grep -q "mcp_servers.deckhand=" "$W/argv.txt" || fail "no hooks or tools in codex's argv there"
grep -q "^SOCKET=$RUN2/core.sock$" "$W/env.txt" || fail "codex there got another core's socket: $(cat "$W/env.txt")"
grep -q "^TOKEN=set$" "$W/env.txt" || fail "codex there got no token"
python3 -I "$W/check.py" "$CTL" tab || fail "this Mac's get_state has no Codex tab of that machine"
# the end: the link drops, the window quits
pkill -f "$ROOT/build/deckhand-core-serve connect" || true
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  fail "the window's script failed (log: $W/run.log)"
fi
echo "remote-codex: forwarded, ran there with that core's own hooks, socket and token, listed here: ok"
