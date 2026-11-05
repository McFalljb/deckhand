#!/bin/sh
# Claude status feeds in quiet test mode (docs/CLAUDE.md §5a, §6a, §6b): never a real claude, never
# the user's ~/.claude. A fake HOME with a fake Claude config folder and a fake `claude` install
# that is too old (~/.local/bin/claude -> versions/2.1.250, PI_DESK_CLAUDE_BIN; never run), the
# fake claude (tests/scripts/fake-claude.py) in Claude tabs: the minimum-version bar, dots from the
# hooks (the fake reports no OSC 7501), background work from a Stop (the Background panel, the
# working dot, a wait that names it), a subagent's current tool and own todos, and a tab whose
# hooks never run (the "hooks not running" bar). Needs ./build.sh (build/claude-code,
# build/pi-desk-cli). Writes build/claude-feeds/ and build/shots/claude-feeds/.
# Usage: tests/scripts/claude-feeds.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/claude-feeds"
rm -rf "$W" build/shots/claude-feeds
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--" "$FAKE_HOME/.claude" \
  "$FAKE_HOME/.local/share/claude/versions" "$FAKE_HOME/.local/bin"
[ -x build/deckhand ] || { echo "claude-feeds scene: build/deckhand missing (./build.sh)"; exit 1; }
[ -x build/pi-desk-cli ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/pi-desk-cli or build/claude-code missing: ./build.sh"; exit 1; }
printf '{"type":"session","version":3,"id":"cccc-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_cccc-1.jsonl"
printf '{\n  "model": "opus"\n}\n' > "$FAKE_HOME/.claude/settings.json"
# the fake install: never run (it would leave a file behind)
printf '#!/bin/sh\ntouch "%s/claude-ran"\n' "$W" > "$FAKE_HOME/.local/share/claude/versions/2.1.250"
chmod +x "$FAKE_HOME/.local/share/claude/versions/2.1.250"
ln -s "$FAKE_HOME/.local/share/claude/versions/2.1.250" "$FAKE_HOME/.local/bin/claude"
LOG="$W/claude.log"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdf.XXXXXX")
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/claude-feeds.txt \
  PI_DESK_DATA_DIR="$W/data" PI_DESK_RUNTIME_DIR="$RUN" PI_DESK_CMD='exec sleep 600' \
  PI_DESK_CLAUDE_CMD="exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\"" \
  PI_DESK_CLAUDE_BIN="$FAKE_HOME/.local/bin/claude" \
  FAKE_CLAUDE_LOG="$LOG" FAKE_CLAUDE_TURN_MS=200 \
  build/deckhand > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q 'ui_command {"type":"quit","confirm"' "$W/run.log"; then
  echo "FAILED (log: $W/run.log)"; fail=1
fi
[ -e "$W/claude-ran" ] && { echo "FAILED: the claude binary was run"; fail=1; } || echo "ok: the claude binary was never run"
# a background command never reaches pi-desk's data (its command log) or output
if grep -rqsF "npm run dev" "$W/data" "$W/run.log"; then echo "FAILED: a background command in pi-desk's data or output"; fail=1; else echo "ok: no background command in pi-desk's data (commands.log) or output"; fi
# the new hooks are async and print nothing; a subagent's prompt and tool input never reach pi-desk
python3 -I - "$LOG" "$W/run.log" <<'PY' || fail=1
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
hooks = [r for r in rows if "hook" in r]
bad = 0
def check(ok, what):
    global bad
    print(("ok: " if ok else "FAILED: ") + what)
    bad += 0 if ok else 1
new = [r for r in hooks if (r["hook"] == "PostToolUse" and r.get("tool") == "Bash") or (r["hook"] == "PreToolUse" and r.get("tool") not in ("Agent", "Task"))]
check(bool(new), "the background-Bash and agent-tool hooks ran")
check(all(r.get("async") and r["out"] == "" for r in new), "they are async and print nothing")
stops = [r for r in hooks if r["hook"] == "Stop"]
check(all(r["exit"] == 0 and r["out"] == "" for r in stops), "Stop hooks exit 0 silently")
log = open(sys.argv[2]).read()
check("FAKE SECRET" not in log and "npm run dev" not in log, "no subagent prompt, tool input or background command in pi-desk's log")
sys.exit(1 if bad else 0)
PY
if [ $fail = 1 ]; then echo "claude-feeds scene failed (logs: $W)"; exit 1; fi
echo "claude-feeds scene ok"
