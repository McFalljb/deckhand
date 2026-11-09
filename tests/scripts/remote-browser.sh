#!/bin/sh
# Remote browser tabs (docs/plans/background-core.md §8.3 P7, §10.4 M6-D): as remote-terms.sh, a
# second core on this Mac (its own HOME, data and runtime dirs; DECKHAND_HUB_WITHOUT_SSHD=1, its
# saved settings let other machines in) is reached through `--via`, no ssh. An agent there (its
# control token, here) opens a browser tab: the page is this window's (CEF, test mode, with
# DECKHAND_CEF_LOOPBACK=1 so the scene's own loopback servers are reachable at all). A data: page is
# refused; a page on this Mac's loopback is refused until the user forwards its port (the bar's
# Forward), then it loads; neither a redirect from it to another loopback port, nor its fetch or
# image there, reaches that port (the trap server counts connections); its WebSocket reaches the
# forwarded port only. A screenshot comes back as bytes and lands in the other core's own shots dir.
# Needs a CEF build (./build.sh). Usage: tests/scripts/remote-browser.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
[ -x build/Deckhand.app/Contents/MacOS/Deckhand ] || { echo "remote-browser: no CEF build (run ./build.sh)"; exit 1; }
W="$ROOT/build/remote-browser"
rm -rf "$W" 2>/dev/null || { sleep 3; rm -rf "$W"; }
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkrb.XXXXXX")
RUN2=$(mktemp -d "${TMPDIR:-/tmp}/dkb2.XXXXXX")
APP=
SRV=
FAKE_PI='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600'
cores() { pgrep -f "deckhand-core-serve serve --run $1" || true; }
tree() { for c in $(pgrep -P "$1"); do tree "$c"; done; echo "$1"; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  cp "$RUN2/core.log" "$W/core2.log" 2>/dev/null || true
  [ -n "$APP" ] && for p in $(tree "$APP"); do kill -9 "$p" 2>/dev/null || true; done
  [ -n "$SRV" ] && kill -9 "$SRV" 2>/dev/null || true
  pkill -9 -f "$W/via.sh" 2>/dev/null || true
  pkill -9 -f "$ROOT/build/deckhand-core-serve connect" 2>/dev/null || true
  for r in "$RUN" "$RUN2"; do
    for p in $(cores "$r"); do kill -9 "$p" 2>/dev/null || true; done
    pkill -9 -f "deckhand-core hold --run $r" 2>/dev/null || true
    rm -rf "$r"
  done
}
trap cleanup EXIT
mkdir -p "$W/data" "$W/data2" "$W/home" "$W/home2" "$W/proj2" "$W/srv"
printf '{"v":1,"settings":{"machines_reachable":true}}\n' > "$W/data2/workspace.json"
# the other machine's dev server (P1, forwarded) and a trap (P2: never forwarded; every connection
# to it is counted)
cat > "$W/srv/servers.py" <<'PY'
import http.server, socket, socketserver, sys, threading
out = sys.argv[1]
def free():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p
trap = socket.socket(); trap.bind(("127.0.0.1", 0)); trap.listen(16); p2 = trap.getsockname()[1]
def count():
    while True:
        c, _ = trap.accept()
        with open(out + "/trap.hits", "a") as f: f.write("hit\n")
        c.close()
threading.Thread(target=count, daemon=True).start()
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/ws"):  # a WebSocket's handshake reached the forwarded port
            with open(out + "/ws.hits", "a") as f: f.write("hit\n")
            self.send_response(404); self.end_headers(); return
        if self.path.startswith("/redirect"):
            self.send_response(302); self.send_header("Location", f"http://127.0.0.1:{p2}/redirected"); self.end_headers(); return
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(page.encode())
srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
p1 = srv.server_address[1]
page = f"""<!doctype html><html><head><title>forwarded</title></head><body><p>FORWARDED-OK</p>
<script>
fetch("http://127.0.0.1:{p2}/fetch").then(() => document.body.append("FETCH-WENT"), () => document.body.append("FETCH-REFUSED"));
var i = document.createElement("img"); i.src = "http://127.0.0.1:{p2}/img"; document.body.appendChild(i);
function ws(u, tag) {{ try {{ var w = new WebSocket(u); w.onclose = () => document.body.append(" " + tag + "-CLOSED"); }} catch (e) {{ document.body.append(" " + tag + "-CLOSED"); }} }}
ws("ws://127.0.0.1:{p2}/ws", "WS2"); ws("ws://0.0.0.0:{p2}/ws", "WS0"); ws("ws://127.0.0.1:{p1}/ws", "WS1");
</script></body></html>"""
open(out + "/ports", "w").write(f"{p1} {p2}\n")
srv.serve_forever()
PY
python3 -I "$W/srv/servers.py" "$W/srv" &
SRV=$!
i=0; while [ ! -s "$W/srv/ports" ]; do i=$((i + 1)); [ $i -gt 50 ] && { echo "remote-browser: the servers did not start"; exit 1; }; sleep 0.1; done
read P1 P2 < "$W/srv/ports"
cat > "$W/via.sh" <<VIA
#!/bin/sh
exec env HOME="$W/home2" DECKHAND_DATA_DIR="$W/data2" DECKHAND_RUNTIME_DIR="$RUN2" DECKHAND_SCRIPT=remote-browser \
  DECKHAND_HUB_WITHOUT_SSHD=1 SHELL=/bin/sh DECKHAND_CMD='$FAKE_PI' "$ROOT/build/deckhand-core-serve" connect "\$@"
VIA
chmod +x "$W/via.sh"
# the window: machines on, the machine added; it forwards the port when the bar asks
cat > "$W/window.txt" <<TXT
# tests/scripts/remote-browser.sh's window: another machine's pages, here
ui_command {"type":"set_remote_machines","on":true}
waitstate 5000 settings.remote_machines true
ui_command {"type":"machine_add","name":"m2","target":"","via":"$W/via.sh"}
waitstate 30000 machines.0.status online
waitstate 60000 pending_confirmations.# 1
clickid confirm_yes
waitstate 10000 machines.0.ports.# 1
# the scene is done with it: its link is dropped
waitstate 150000 machines.0.status offline
quit_window
TXT
env HOME="$W/home" CFFIXED_USER_HOME="$W/home" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT="$W/window.txt" \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD="$FAKE_PI" DECKHAND_CEF_LOOPBACK=1 \
  build/deckhand > "$W/run.log" 2>&1 &
APP=$!
until_log() { # file pattern seconds
  i=0
  while ! grep -q "$2" "$1" 2>/dev/null; do
    i=$((i + 1)); [ $i -gt $(($3 * 10)) ] && { echo "remote-browser: no \"$2\" in $1 within $3 s"; tail -20 "$1" 2>/dev/null; exit 1; }
    sleep 0.1
  done
}
until_log "$RUN/core.log" "machine m2: online" 30
TOK=$(sed -n "s/^export DECKHAND_SOCKET='\(.*\)' DECKHAND_TOKEN='\(.*\)'$/\2/p" "$RUN2/core.log" | tail -1)
[ -n "$TOK" ] || { echo "no control token in the other core's log"; cat "$RUN2/core.log"; exit 1; }
ctl2() { DECKHAND_SOCKET="$RUN2/core.sock" DECKHAND_TOKEN="$TOK" HOME="$W/home2" build/deckhand --ctl "$1" 2>&1 || true; }
id_of() { sed -n 's/.*"created_id":\([0-9]*\).*/\1/p' | head -1; }
fail() { echo "remote-browser: $1"; exit 1; }
PID=$(ctl2 "{\"type\":\"add_project\",\"cwd\":\"$W/proj2\"}" | id_of)
[ -n "$PID" ] || fail "add_project on the other core failed"
SID=$(ctl2 "{\"type\":\"new_chat\",\"project_id\":$PID}" | id_of)
[ -n "$SID" ] || fail "new_chat on the other core failed"
# a data: page is never another machine's
OUT=$(ctl2 "{\"type\":\"browser_open\",\"session\":$SID,\"url\":\"data:text/html,<p>hi</p>\"}")
echo "$OUT" | grep -q '"ok":false' || fail "a data: page opened: $OUT"
# a page of its own (the fixtures' scheme: no network) opens in this window
OUT=$(ctl2 "{\"type\":\"browser_open\",\"session\":$SID,\"url\":\"deckhand-test://web/browser.html\"}")
TAB=$(echo "$OUT" | id_of)
[ -n "$TAB" ] || fail "browser_open failed: $OUT"
OUT=$(ctl2 "{\"type\":\"browser_wait\",\"tab_id\":$TAB,\"for\":\"text\",\"value\":\"Press me\",\"timeout_ms\":30000}")
echo "$OUT" | grep -q '"ok":true' || fail "the page did not load here: $OUT"
# this Mac's loopback: refused, and the bar asks to forward the port (the window's script says Forward)
OUT=$(ctl2 "{\"type\":\"browser_navigate\",\"tab_id\":$TAB,\"url\":\"http://localhost:$P1/\"}")
echo "$OUT" | grep -q 'needs_forward' || fail "this Mac's loopback was not refused: $OUT"
[ ! -s "$W/srv/trap.hits" ] || fail "the trap port was reached before anything was forwarded"
i=0; until ctl2 "{\"type\":\"browser_navigate\",\"tab_id\":$TAB,\"url\":\"http://localhost:$P1/\"}" | grep -q '"ok":true'; do
  i=$((i + 1)); [ $i -gt 100 ] && fail "the forwarded port never opened"; sleep 0.2
done
OUT=$(ctl2 "{\"type\":\"browser_wait\",\"tab_id\":$TAB,\"for\":\"text\",\"value\":\"FORWARDED-OK\",\"timeout_ms\":30000}")
echo "$OUT" | grep -q '"ok":true' || fail "the forwarded port did not load: $OUT"
# its fetch of another loopback port of this Mac was refused (the page says so)
OUT=$(ctl2 "{\"type\":\"browser_wait\",\"tab_id\":$TAB,\"for\":\"text\",\"value\":\"FETCH-REFUSED\",\"timeout_ms\":30000}")
echo "$OUT" | grep -q '"ok":true' || fail "the page's fetch of an unforwarded port was not refused: $OUT"
# its WebSockets: to the forwarded port, yes; to an unforwarded loopback port (or 0.0.0.0, which
# reaches this Mac's loopback), never (the context's proxy: CEF hands no WebSocket to the handler)
OUT=$(ctl2 "{\"type\":\"browser_wait\",\"tab_id\":$TAB,\"for\":\"text\",\"value\":\"WS1-CLOSED\",\"timeout_ms\":30000}")
echo "$OUT" | grep -q '"ok":true' || fail "the WebSocket to the forwarded port never finished: $OUT"
for t in WS2 WS0; do
  OUT=$(ctl2 "{\"type\":\"browser_wait\",\"tab_id\":$TAB,\"for\":\"text\",\"value\":\"$t-CLOSED\",\"timeout_ms\":30000}")
  echo "$OUT" | grep -q '"ok":true' || fail "the WebSocket $t never finished: $OUT"
done
[ -s "$W/srv/ws.hits" ] || fail "the WebSocket to the forwarded port never reached it"
# a redirect from it to an unforwarded loopback port goes nowhere
ctl2 "{\"type\":\"browser_navigate\",\"tab_id\":$TAB,\"url\":\"http://localhost:$P1/redirect\"}" > /dev/null
sleep 2
# a screenshot: bytes back to the other core, a file in its own shots dir
OUT=$(ctl2 "{\"type\":\"browser_screenshot\",\"tab_id\":$TAB}")
SHOT=$(echo "$OUT" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p' | head -1)
case "$SHOT" in "$W/data2/"*) ;; *) fail "the screenshot is not in the other core's data dir: $OUT" ;; esac
[ "$(head -c 4 "$SHOT" | od -An -tx1 | tr -d ' \n')" = 89504e47 ] || fail "$SHOT is not a PNG"
[ -z "$(ls "$W/data/apps/shots" 2>/dev/null)" ] || fail "a screenshot was written on this Mac"
# nothing of the forwarded page's (fetch, image, WebSockets) nor the redirect reached the trap
[ ! -s "$W/srv/trap.hits" ] || fail "the unforwarded port was reached $(wc -l < "$W/srv/trap.hits") times"
pkill -f "$ROOT/build/deckhand-core-serve connect" || true # the window's script ends on the link's drop
wait "$APP" || true
APP=
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command|core refused" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "remote-browser: the window's script failed (log: $W/run.log)"; tail -20 "$W/run.log"; exit 1
fi
grep -q "a request refused\|a redirect refused" "$W/run.log" || fail "the window's CEF refused nothing (log: $W/run.log)"
echo "remote-browser: a page opened here, data: and loopback refused, the port forwarded and loaded, nothing else reached; the screenshot is the other core's"
echo "remote-browser: ok"
