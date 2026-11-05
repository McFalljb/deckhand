#!/bin/sh
# Claude Code accounts and Claude sessions found on disk in quiet test mode (docs/CLAUDE.md §1b,
# §4b): never a real claude, never the user's ~/.claude*. A fake HOME with two fake accounts
# (~/.claude and ~/.claude-work: fake account files, read by stat only) whose projects/ hold fake
# transcripts of the project (one each, run outside pi-desk, plus a subagent file that is never a
# row); a pi session beside them. Rows show the harness icons and account names (light and dark),
# + New session opens the picker with a row per account, a found row resumes under its account by the
# transcript's path (CLAUDE_CONFIG_DIR as the fake claude saw it).
# Writes build/claude-accounts/ and build/shots/claude-accounts/. Needs ./build.sh.
# Usage: tests/scripts/claude-accounts.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/claude-stub.sh
W="$ROOT/build/claude-accounts"
rm -rf "$W" build/shots/claude-accounts
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/my proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
[ -x build/deckhand ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/deckhand or build/claude-code missing: ./build.sh"; exit 1; }
printf '{"type":"session","version":3,"id":"pppp-1","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Tidy the README"}}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_pppp-1.jsonl"
SLUG=$(printf '%s' "$PROJ" | sed 's/[^a-zA-Z0-9]/-/g')
line() { printf '{"parentUuid":null,"isSidechain":false,"userType":"external","cwd":"%s","sessionId":"%s","version":"2.1.317","type":"user","message":{"role":"user","content":"%s"},"uuid":"u1","timestamp":"2026-11-01T10:00:00.000Z"}\n' "$PROJ" "$1" "$2"; }
for acct in .claude .claude-work; do
  mkdir -p "$FAKE_HOME/$acct/projects/$SLUG"
  printf '{"fake":true}\n' > "$FAKE_HOME/$acct/.claude.json"
done
line 11111111-0000-4000-8000-000000000001 "Plan the parser" > "$FAKE_HOME/.claude/projects/$SLUG/11111111-0000-4000-8000-000000000001.jsonl"
line 22222222-0000-4000-8000-000000000002 "Fix the login bug" > "$FAKE_HOME/.claude-work/projects/$SLUG/22222222-0000-4000-8000-000000000002.jsonl"
line 33333333-0000-4000-8000-000000000003 "a subagent's task" > "$FAKE_HOME/.claude-work/projects/$SLUG/agent-33333333.jsonl"
touch -t 202611011000 "$FAKE_HOME/.claude/projects/$SLUG/11111111-0000-4000-8000-000000000001.jsonl"
touch -t 202611021000 "$FAKE_HOME/.claude-work/projects/$SLUG/22222222-0000-4000-8000-000000000002.jsonl"
claude_stub "$FAKE_HOME"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdca.XXXXXX") # a short runtime dir: the socket path must fit sun_path
CLAUDE_CMD="printf '%s\n' \"\${CLAUDE_CONFIG_DIR:-unset}\" >> '$W/ccd.txt'; exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\""
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/claude-accounts.txt \
  PI_DESK_DATA_DIR="$W/data" PI_DESK_RUNTIME_DIR="$RUN" PI_DESK_CMD='exec sleep 600' \
  PI_DESK_CLAUDE_CMD="$CLAUDE_CMD" FAKE_CLAUDE_LOG="$W/claude.log" FAKE_CLAUDE_TURN_MS=200 \
  "$ROOT/build/deckhand" "$PROJ" > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
fail=0
grep -E "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q 'ui_command {"type":"quit","confirm"' "$W/run.log"; then fail=1; fi
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAILED: $1"; fail=1; fi; }
chk "the work row resumed by its transcript's path" 'grep "\"start\"" "$W/claude.log" | grep -q -- "--resume\", \"$FAKE_HOME/.claude-work/projects/$SLUG/22222222-0000-4000-8000-000000000002.jsonl"'
chk "under the work account" 'grep -qx "$FAKE_HOME/.claude-work" "$W/ccd.txt"'
chk "the transcripts untouched" '[ "$(wc -l < "$FAKE_HOME/.claude-work/projects/$SLUG/22222222-0000-4000-8000-000000000002.jsonl" | tr -d " ")" = 1 ]'
if [ $fail = 1 ]; then echo "claude-accounts scene failed (log: $W/run.log)"; exit 1; fi
echo "claude-accounts scene ok"
