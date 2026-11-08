#!/bin/sh
# Which hosts Chromium's own services try to reach (docs/BROWSER.md, network
# policy): a local page idles 20 s in test mode, which stays offline (no name
# resolves, a dead proxy), while Chromium's net-log records every request.
# Allowed: Safe Browsing only. Needs a CEF build. Writes build/browser-netpolicy/.
# Usage: tests/scripts/browser-netpolicy.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/browser-netpolicy"
rm -rf "$W"; FAKE_HOME="$W/home"; PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"nnnn-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_nnnn-1.jsonl"
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/browser-netpolicy.txt DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_CEF_NETLOG="$W/netlog.json" DECKHAND_CMD='exec sleep 600' build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
grep -q "done: .* 0 failed" "$W/run.log" || { echo "netpolicy: the scene failed (log: $W/run.log)"; exit 1; }
[ -s "$W/netlog.json" ] || { echo "netpolicy: no net-log written"; exit 1; }
# hosts in URLs and host fields of the log (it may be cut short at exit: read it as text)
python3 -I - "$W/netlog.json" > "$W/hosts.txt" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
hosts = set(re.findall(r'"(?:url|original_url|host)"\s*:\s*"(?:[a-z-]+://)?([A-Za-z0-9.-]+\.[A-Za-z]{2,})', text))
hosts |= set(re.findall(r'https?://([A-Za-z0-9.-]+\.[A-Za-z]{2,})', text))
for h in sorted(hosts): print(h)
PY
echo "hosts Chromium tried to reach:"; sed 's/^/  /' "$W/hosts.txt"
bad=$(grep -vE '^(safebrowsing\.googleapis\.com|safebrowsing\.google\.com|sb-ssl\.google\.com|safebrowsingohttpgateway\.googleapis\.com)$' "$W/hosts.txt" || true)
if [ -n "$bad" ]; then echo "netpolicy FAILED: hosts outside Safe Browsing:"; echo "$bad" | sed 's/^/  /'; exit 1; fi
echo "netpolicy ok"
