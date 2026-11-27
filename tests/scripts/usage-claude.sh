#!/bin/sh
# The USAGE section's Claude Code rows (docs/GUIDE.md "Usage"; docs/CLAUDE-TABS.md §6c;
# src/core/usage_claude.odin) against the fake claude (tests/scripts/fake-claude.py): never a real
# claude, never the user's ~/.claude. Three config folders: the default (~/.claude: a status line
# of the user's, live numbers in fake-rate-limits.json, and a background answer), "Work" (a Max
# plan near its limits, an Opus window) and "Key" (an API key: no plan limits). Each folder's
# .credentials.json and .claude.json are FIFOs: the fake logs whoever holds one open, and this
# script checks at the end that nobody does (Deckhand never reads them).
# The run (usage-claude.txt): the background reads (print mode: initialize, get_usage, never a
# prompt), a Claude tab whose status line goes through `deckhand statusline` (the numbers to
# Deckhand, the user's own line printed unchanged), the live numbers in the row with the model
# windows kept, the switches. Then the fake's log is checked. Needs ./build.sh (build/claude-code,
# build/deckhand-cli). Writes build/usage-claude/ and build/shots/usage-claude/.
# Usage: tests/scripts/usage-claude.sh
set -eu
unset CLAUDE_CONFIG_DIR CODEX_HOME
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/usage-claude"
rm -rf "$W" build/shots/usage-claude
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--" \
  "$FAKE_HOME/.local/share/claude/versions" "$FAKE_HOME/.local/bin"
[ -x build/deckhand ] || { echo "usage-claude scene: build/deckhand missing (./build.sh)"; exit 1; }
[ -x build/deckhand-cli ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/deckhand-cli or build/claude-code missing: ./build.sh"; exit 1; }
printf '{"type":"session","version":3,"id":"uuuu-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_uuuu-1.jsonl"
# the fake install: never run (it would leave a file behind)
printf '#!/bin/sh\ntouch "%s/claude-ran"\n' "$W" > "$FAKE_HOME/.local/share/claude/versions/2.1.332"
chmod +x "$FAKE_HOME/.local/share/claude/versions/2.1.332"
ln -s "$FAKE_HOME/.local/share/claude/versions/2.1.332" "$FAKE_HOME/.local/bin/claude"
NOW=$(date +%s)
iso() { python3 -I -c 'import sys,datetime;print(datetime.datetime.fromtimestamp(int(sys.argv[1]),datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
R5=$(iso $((NOW + 3 * 3600)))
R7=$(iso $((NOW + 4 * 86400)))
folder() { # DIR FAKE-USAGE-JSON
  mkdir -p "$1"
  mkfifo "$1/.credentials.json" "$1/.claude.json"
  printf '%s\n' "$2" > "$1/fake-usage.json"
}
usage() { # PLAN 5H WK OPUS
  printf '{"account":{"subscriptionType":"%s","email":"someone@example.com","apiProvider":"firstParty"},"usage":{"subscription_type":"%s","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":%s,"resets_at":"%s"},"seven_day":{"utilization":%s,"resets_at":"%s"},"seven_day_opus":{"utilization":%s,"resets_at":"%s"},"seven_day_sonnet":null,"extra_usage":{"is_enabled":false}}}}' \
    "$1" "$1" "$2" "$R5" "$3" "$R7" "$4" "$R7"
}
folder "$FAKE_HOME/.claude" "$(usage pro 30 10 5)"
folder "$FAKE_HOME/claude-work" "$(usage max 85 97 60)"
folder "$FAKE_HOME/claude-key" '{"account":{"apiKeySource":"ANTHROPIC_API_KEY","apiProvider":"firstParty"},"usage":{"rate_limits_available":false,"rate_limits":null}}'
# the default's own status line, and the live numbers its tabs' status line JSON carries
cat > "$FAKE_HOME/.claude/settings.json" <<JSON
{"statusLine":{"type":"command","command":"cat > '$W/user-stdin.json'; printf '\\\\033[32mmy line\\\\033[0m  x'","padding":1,"refreshInterval":7}}
JSON
printf '{"five_hour":{"used_percentage":42,"resets_at":%d},"seven_day":{"used_percentage":18,"resets_at":%d}}\n' $((NOW + 2 * 3600)) $((NOW + 3 * 86400)) \
  > "$FAKE_HOME/.claude/fake-rate-limits.json"
LOG="$W/claude.log"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdu.XXXXXX")
fail=0
env HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/usage-claude.txt \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD='exec sleep 600' \
  DECKHAND_CLAUDE_CMD="exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\"" \
  DECKHAND_CLAUDE_BIN="$FAKE_HOME/.local/bin/claude" DECKHAND_CLAUDE_MANAGED_DIR= \
  FAKE_CLAUDE_LOG="$LOG" FAKE_CLAUDE_TURN_MS=200 \
  build/deckhand > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q 'ui_command {"type":"quit","confirm"' "$W/run.log"; then
  echo "FAILED (log: $W/run.log)"; fail=1
fi
[ -e "$W/claude-ran" ] && { echo "FAILED: the claude binary was run"; fail=1; } || echo "ok: the claude binary was never run"
python3 -I - "$LOG" "$W/run.log" "$W/data" "$FAKE_HOME" "$W/user-stdin.json" <<'PY' || fail=1
import json, os, sys
log, runlog, data, home, stdin_file = sys.argv[1:6]
rows = [json.loads(l) for l in open(log) if l.strip()]
bad = 0
def check(ok, what):
    global bad
    print(("ok: " if ok else "FAILED: ") + what)
    bad += 0 if ok else 1
starts = [r for r in rows if "probe_start" in r]
dirs = {r["config_dir"] for r in starts}
want = {f"{home}/.claude", f"{home}/claude-work", f"{home}/claude-key"}
check(want <= dirs, f"a background read of every folder ({sorted(dirs)})")
check(all(not r["probe_credentials_open"] for r in starts), "nobody held .credentials.json or .claude.json open while claude ran")
check(all("--no-session-persistence" in r["probe_start"] and "--strict-mcp-config" in r["probe_start"] and '{"disableAllHooks":true}' in r["probe_start"] for r in starts), "print mode without hooks, MCP servers or a saved session")
check(all(r["env"]["ENABLE_CLAUDEAI_MCP_SERVERS"] == "false" for r in starts), "claude.ai's MCP servers off")
probes = [r["probe"] for r in rows if "probe" in r]
check(set(probes) == {"initialize", "get_usage"}, f"only initialize and get_usage ({sorted(set(probes))})")
check(all(r["request"].get("skip_behaviors") is True for r in rows if r.get("probe") == "get_usage"), "get_usage skips the transcript scan")
check(not any("probe_prompt" in r for r in rows), "never a prompt")
check(len([r for r in rows if "probe_end" in r]) == len(starts), "every background claude ended")
lines = [r for r in rows if "statusline" in r]
check(bool(lines) and all(r["statusline"] == "\x1b[32mmy line\x1b[0m  x" and r["exit"] == 0 for r in lines), "the user's status line printed unchanged through deckhand statusline")
check(bool(lines) and all(r["padding"] == 1 and r["refresh"] == 7 for r in lines), "its padding and refreshInterval kept")
try:
    seen = json.load(open(stdin_file))
except (OSError, ValueError):
    seen = {}
check(seen.get("session_name") == "FAKE SECRET SESSION NAME", "the user's status line got Claude Code's input in full")
text = open(runlog).read()
for root, _, files in os.walk(data):
    for f in files:
        try:
            text += open(os.path.join(root, f), errors="replace").read()
        except OSError:
            pass
check("FAKE SECRET SESSION NAME" not in text and "someone@example.com" not in text and "my line" not in text, "no session name, email or status line text in Deckhand's log or data")
sys.exit(1 if bad else 0)
PY
for d in "$FAKE_HOME/.claude" "$FAKE_HOME/claude-work" "$FAKE_HOME/claude-key"; do
  for f in .credentials.json .claude.json; do
    if ! python3 -I -c 'import os,sys,errno
try:
    os.close(os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)); sys.exit(1)
except OSError as e:
    sys.exit(0 if e.errno == errno.ENXIO else 1)' "$d/$f"; then echo "FAILED: $d/$f is open for reading"; fail=1; fi
  done
done
grep -q '"source":"claude"' "$W/data/workspace.json" || { echo "FAILED: no Claude usage in workspace.json"; fail=1; }
[ $fail = 0 ] && echo "usage-claude scene ok" || { echo "usage-claude scene failed (logs: $W)"; exit 1; }
