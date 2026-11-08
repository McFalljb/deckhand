#!/bin/sh
# Claude-only sessions in quiet test mode (docs/CLAUDE.md §1, §4): never a real claude. A fake
# claude (tests/scripts/fake-claude.py) runs the bundled plugin's hooks; a stand-in `claude` in
# the fake HOME's ~/.local/bin makes Claude Code "installed" (claude-stub.sh; never run).
#   1. claude-sessions-1.txt: + New session (the picker, Claude Code), its row (marked Claude) beside a pi session,
#      the row menu (Pin, Rename…), the filter, close, a click on the closed row resumes it;
#      the row's ⓘ, Copy session info, Reveal and Copy path (its transcript in a FAKE Claude
#      config dir), the model (SessionStart, PostModelSwitch) in the tooltip, the question and
#      error dots, the rename pushed back as sessionTitle, ⇧⌘N's picker (Claude Code first)
#   2. claude-sessions-2.txt: relaunch: the Claude-only session comes back and resumes
#   3. claude-sessions-3.txt: no Claude Code anywhere (stand-in gone, PATH without claude): pi
#      works, the Claude buttons say so and a click says how to install it, the restored session
#      does not start, its row still lists; nothing starts claude
# A fake HOME and pi, a temp data dir. Needs ./build.sh (the app, build/claude-code).
# Writes build/claude-sessions/ and build/shots/claude-sessions/. Usage: tests/scripts/claude-sessions.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
. tests/scripts/claude-stub.sh
W="$ROOT/build/claude-sessions"
rm -rf "$W" build/shots/claude-sessions
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
[ -x build/deckhand ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/deckhand or build/claude-code missing: ./build.sh"; exit 1; }
printf '{"type":"session","version":3,"id":"pppp-1","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Tidy the README"}}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_pppp-1.jsonl"
touch -t 202610301000 "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_pppp-1.jsonl"
fail=0
for n in 1 2 3; do
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdcs.XXXXXX") # a short runtime dir: the socket path must fit sun_path
  path="$PATH"
  CLAUDE_CMD="exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\""
  if [ $n = 3 ]; then
    rm -f "$FAKE_HOME/.local/bin/claude"
    path=/usr/bin:/bin:/usr/sbin:/sbin
    if PATH=$path command -v claude >/dev/null 2>&1; then echo "run 3: skipped (claude in $path)"; rm -rf "$RUN"; continue; fi
    # anything that started claude now would leave this file (it never runs the fake or a real one)
    CLAUDE_CMD="touch '$W/claude-ran'; exec sleep 600"
  else
    claude_stub "$FAKE_HOME"
  fi
  PATH="$path" HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/claude-sessions-$n.txt \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD='exec sleep 600' \
    DECKHAND_CLAUDE_CMD="$CLAUDE_CMD" FAKE_CLAUDE_LOG="$W/claude.log" \
    FAKE_CLAUDE_SESSION=5e551011-1111-4222-8333-444455556666 FAKE_CLAUDE_TURN_MS=200 \
    FAKE_CLAUDE_PROJECTS="$FAKE_HOME/.claude/projects" \
    "$ROOT/build/deckhand" > "$W/run$n.log" 2>&1 || true
  rm -rf "$RUN"
  grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run$n.log" | sed "s/^/run $n: /" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run$n.log" || ! grep -q 'ui_command {"type":"quit","confirm"' "$W/run$n.log"; then
    echo "run $n: FAILED (log: $W/run$n.log)"; fail=1
  fi
done
[ -e "$W/claude-ran" ] && { echo "FAILED: something started claude while it was not installed"; fail=1; } || echo "ok: nothing started claude without Claude Code"
# the user's rename went back to Claude Code as its session title (the resume's SessionStart)
grep -q 'sessionTitle.*Parser design' "$W/claude.log" && echo "ok: the rename is Claude Code's session title" || { echo "FAILED: no sessionTitle"; fail=1; }
# each start of the fake: new, ⇧⌘N's, resumed (row click), restored
n=$(grep -c '"start"' "$W/claude.log" || true)
[ "$n" = 4 ] && echo "ok: claude started four times (new, ⇧⌘N, resumed from its row, restored)" || { echo "FAILED: claude started $n times (want 4)"; fail=1; }
[ "$(grep '"start"' "$W/claude.log" | grep -c -- '"--resume", "5e551011')" = 2 ] && echo "ok: the row and the restore resume it" || { echo "FAILED: no --resume"; fail=1; }
if [ $fail = 1 ]; then echo "claude-sessions scene failed (logs: $W)"; exit 1; fi
echo "claude-sessions scene ok"
