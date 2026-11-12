#!/bin/sh
# Claude Code runtime operations in quiet test mode (docs/CLAUDE.md §4a): never a real claude, never
# the user's ~/.claude. A fake HOME with a fake Claude config folder (~/.claude: settings.json,
# CLAUDE.md, a credentials file and a transcript that must never show), a fake `claude` install
# (~/.local/bin/claude -> versions/2.1.300, DECKHAND_CLAUDE_BIN; never run), the fake claude
# (tests/scripts/fake-claude.py) in a Claude tab. Claude's CLAUDE.md edited outside → the Claude
# bar → Restart (confirmed) resumes the conversation; claude relinked to 2.1.301 → the update bar →
# Restart; the Settings page's Claude Code card; Claude exits with an error → Restart with
# model… → Deckhand pastes /model. Needs ./build.sh (build/claude-code, build/deckhand-cli).
# Writes build/claude-runtime/ (run.log, claude.log) and build/shots/claude-runtime/.
# Usage: tests/scripts/claude-runtime.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/claude-runtime"
rm -rf "$W" build/shots/claude-runtime
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
CFG="$FAKE_HOME/.claude"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--" "$CFG/projects/-proj" "$CFG/commands" \
  "$FAKE_HOME/.local/share/claude/versions" "$FAKE_HOME/.local/bin"
[ -x build/deckhand-cli ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/deckhand-cli or build/claude-code missing: ./build.sh"; exit 1; }
printf '{"type":"session","version":3,"id":"cccc-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_cccc-1.jsonl"
printf '{\n  "model": "opus"\n}\n' > "$CFG/settings.json"
printf '# mine\n' > "$CFG/CLAUDE.md"
printf '{"claudeAiOauth":{"accessToken":"FAKE-CREDENTIAL"}}\n' > "$CFG/.credentials.json"
printf '{"oauthAccount":{}}\n' > "$FAKE_HOME/.claude.json"
printf '{"FAKE-TRANSCRIPT":1}\n' > "$CFG/projects/-proj/abc.jsonl"
# the fake install: never run (it would leave a file behind)
for v in 2.1.300 2.1.301; do
  printf '#!/bin/sh\ntouch "%s/claude-ran"\n' "$W" > "$FAKE_HOME/.local/share/claude/versions/$v"
  chmod +x "$FAKE_HOME/.local/share/claude/versions/$v"
done
ln -s "$FAKE_HOME/.local/share/claude/versions/2.1.300" "$FAKE_HOME/.local/bin/claude"
printf 'ln -sfn %s %s\n' "$FAKE_HOME/.local/share/claude/versions/2.1.301" "$FAKE_HOME/.local/bin/claude" > "$FAKE_HOME/update-claude.sh"
LOG="$W/claude.log"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdr.XXXXXX")
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/claude-runtime.txt \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD='exec sleep 600' \
  DECKHAND_CLAUDE_CMD="exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\"" \
  DECKHAND_CLAUDE_BIN="$FAKE_HOME/.local/bin/claude" \
  FAKE_CLAUDE_LOG="$LOG" FAKE_CLAUDE_SESSION=0c1a0de0-2222-4222-8333-444455556666 FAKE_CLAUDE_TURN_MS=200 \
  build/deckhand > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q 'ui_command {"type":"quit","confirm"' "$W/run.log"; then
  echo "FAILED (log: $W/run.log)"; fail=1
fi
# the restarts resumed the conversation; the user's /model went in once, as Deckhand's paste
n=$(grep -c '"--resume", "0c1a0de0-2222' "$LOG" || true)
[ "$n" -ge 3 ] && echo "ok: $n resumed starts" || { echo "FAILED: $n resumed starts (want 3)"; fail=1; }
m=$(grep -c '"prompt": "/model"' "$LOG" || true)
[ "$m" = 1 ] && echo "ok: /model pasted once" || { echo "FAILED: /model pasted $m times"; fail=1; }
[ -e "$W/claude-ran" ] && { echo "FAILED: the claude binary was run"; fail=1; } || echo "ok: the claude binary was never run"
# credentials and transcripts never reach Deckhand's output or data
if grep -rqsF -e FAKE-CREDENTIAL -e FAKE-TRANSCRIPT "$W/run.log" "$W/data"; then echo "FAILED: Claude's credentials or transcript in Deckhand's output or data"; fail=1; else echo "ok: no Claude credentials or transcript in Deckhand's output or data"; fi
if [ $fail = 1 ]; then echo "claude-runtime scene failed (logs: $W)"; exit 1; fi
echo "claude-runtime scene ok"
