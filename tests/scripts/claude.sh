#!/bin/sh
# Claude Code tabs in quiet test mode (docs/CLAUDE.md): never a real claude. A fake claude
# (tests/scripts/fake-claude.py) runs the bundled plugin's hooks and `deckhand` CLI as Claude
# Code would (build/claude-code and build/deckhand-cli, from ./build.sh). Run 1
# (claude-1.txt): the "+" menu's New Claude tab, the SessionStart hook's session id, the CLI
# against a browser page and the fake app (and `app open` of the project's declared app, behind the
# view; restart, close), the token refused outside the tab, an agent's text
# held while the user types, comments with the next message and Send now, Claude's todos and
# subagents in the right column, Resume from the project's menu, the dead tab's Restart (exit 3, 127).
# Run 2 (claude-2.txt): the same data dir; the tab comes back and resumes. Then the fake's log
# is checked (what the hooks and the CLI printed). A fake HOME and pi, a temp data dir. Needs a
# CEF build (./build.sh) and build/fake-app (./build.sh test).
# Both runs start Deckhand with a Claude Code session's markers in its environment (as when it is
# `open`ed from a shell inside Claude Code): no pi or Claude tab may get them (src/login_env.odin).
# Writes build/claude/ (run1.log, run2.log, claude.log, pi-env.txt, claude-env.txt) and build/shots/claude/.
# Usage: tests/scripts/claude.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
. tests/scripts/claude-stub.sh
W="$ROOT/build/claude"
rm -rf "$W" build/shots/claude
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--" "$PROJ/.deckhand"
# the project's declared app: what the CLI's `app open fake` opens
printf '{"apps":[{"name":"fake","argv":["%s/build/fake-app"]}]}\n' "$ROOT" > "$PROJ/.deckhand/apps.json"
# Claude Code "installed" (Deckhand only looks that it is there, docs/CLAUDE.md §1): a stand-in in the
# native installer's place; DECKHAND_CLAUDE_CMD runs the fake instead, so it never runs
claude_stub "$FAKE_HOME"
if [ ! -x build/Deckhand.app/Contents/MacOS/Deckhand ]; then echo "claude scene: no CEF build (run ./build.sh)"; exit 1; fi
[ -x build/fake-app ] || { echo "build/fake-app missing: ./build.sh test"; exit 1; }
[ -x build/deckhand-cli ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/deckhand-cli or build/claude-code missing: ./build.sh"; exit 1; }
printf '{"type":"session","version":3,"id":"cccc-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_cccc-1.jsonl"
LOG="$W/claude.log"
# what a running claude sets in its children (code.claude.com/docs/en/env-vars)
MARKERS="CLAUDECODE=1 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_EXECPATH=/parent/claude CLAUDE_CODE_MESSAGING_SOCKET=/parent/sock CLAUDE_CODE_MESSAGING_TOKEN=parent-token CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_SESSION_ID=parent-session CLAUDE_PID=4242 CLAUDE_CODE_SSE_PORT=1234"
# what a tab's environment holds of Claude's (names, token values masked), and that it started:
# never the whole environment (keys, the tab's token) into build/
ENVDUMP="{ echo started; /usr/bin/env | grep -E '^(CLAUDE|DECKHAND_CLAUDE_TAB)' | sed -E 's/^([A-Z_]*TOKEN[A-Z_]*)=.*/\\1=<masked>/'; }"
fail=0
for n in 1 2; do
  # a short runtime dir: the socket path must fit sun_path
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdc.XXXXXX")
  env $MARKERS HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/claude-$n.txt \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD="$ENVDUMP >> '$W/pi-env.txt'; exec sleep 600" \
    DECKHAND_CLAUDE_CMD="$ENVDUMP >> '$W/claude-env.txt'; exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\"" \
    FAKE_CLAUDE_LOG="$LOG" FAKE_CLAUDE_TOKEN_FILE="$W/tokens" FAKE_CLAUDE_SESSION=0c1a0de0-1111-4222-8333-444455556666 FAKE_CLAUDE_TURN_MS=200 \
    build/deckhand > "$W/run$n.log" 2>&1 || true
  rm -rf "$RUN"
  grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run$n.log" | sed "s/^/run $n: /" || true
  # each run ends with a confirmed quit (which saves the workspace)
  if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run$n.log" || ! grep -q 'ui_command {"type":"quit","confirm"' "$W/run$n.log"; then
    echo "run $n: FAILED (log: $W/run$n.log)"; fail=1
  fi
done
# no tab got the parent session's markers (and each kind of tab did start)
for f in pi-env claude-env; do
  if [ ! -s "$W/$f.txt" ]; then echo "FAILED: no $f.txt (the tab did not start)"; fail=1
  elif grep -E '^(CLAUDECODE|CLAUDE_CODE_CHILD_SESSION|CLAUDE_CODE_ENTRYPOINT|CLAUDE_CODE_EXECPATH|CLAUDE_CODE_MESSAGING_[A-Z_]*|CLAUDE_CODE_SESSION_[A-Z_]*|CLAUDE_PID|CLAUDE_CODE_SSE_PORT)=' "$W/$f.txt"; then
    echo "FAILED: a Claude Code session marker in a tab's environment ($f.txt)"; fail=1
  else echo "ok: no Claude Code session marker in $f.txt"; fi
done
# what the fake claude saw: hooks, CLI results, prompts and their context
python3 -I "$ROOT/tests/scripts/claude-check.py" "$LOG" "$W/data" || fail=1
# the tabs' tokens (one per start) never reach what Deckhand writes: its output, logs, saved files
n=0
while read -r tok; do
  [ ${#tok} = 64 ] || { echo "FAILED: no token in the tab's environment"; fail=1; continue; }
  n=$((n + 1))
  if grep -rqsF "$tok" "$W/run1.log" "$W/run2.log" "$W/data" "$LOG"; then echo "FAILED: a Claude tab's token in Deckhand's output or data"; fail=1; fi
done < "$W/tokens"
[ $n = 5 ] && echo "ok: five tokens, none in Deckhand's output or data" || { echo "FAILED: $n tokens (want 5)"; fail=1; }
[ "$(sort -u "$W/tokens" | wc -l | tr -d ' ')" = 5 ] && echo "ok: a new token at each start" || { echo "FAILED: a token was reused"; fail=1; }
# what the hooks must never pass on: a subagent's prompt and result
if grep -rqsF "FAKE SECRET" "$W/run1.log" "$W/run2.log" "$W/data"; then echo "FAILED: a subagent's prompt or result reached Deckhand"; fail=1; else echo "ok: no subagent prompt or result in Deckhand's output or data"; fi
# the rename's bridge (0.1.7): Claude tabs started before it (or held across the update) run the
# CLI by its old name, Contents/MacOS/pi-desk-cli (PI_DESK_CLI, a read-only tab's guard hook)
A="$ROOT/build/Deckhand.app/Contents/MacOS"
[ "$(readlink "$A/pi-desk-cli")" = deckhand-cli ] && echo "ok: pi-desk-cli links to deckhand-cli in the bundle" || { echo "FAILED: no pi-desk-cli -> deckhand-cli link in the bundle"; fail=1; }
rc=0; printf '%s' '{"tool_name":"Bash","tool_input":{"command":"rm -rf x"}}' | "$A/pi-desk-cli" hook readonly >/dev/null 2>&1 || rc=$?
[ $rc = 2 ] && echo "ok: the read-only guard by its old path still denies" || { echo "FAILED: pi-desk-cli hook readonly exit $rc (want 2)"; fail=1; }
rc=0; printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | "$A/pi-desk-cli" hook readonly >/dev/null 2>&1 || rc=$?
[ $rc = 0 ] && echo "ok: and allows a read" || { echo "FAILED: pi-desk-cli hook readonly on Read: exit $rc (want 0)"; fail=1; }
old=$(env -i PATH=/usr/bin:/bin PI_DESK_CLI="$A/pi-desk-cli" PI_DESK_SOCKET=/nonexistent/old.sock PI_DESK_CLAUDE_TOKEN=x build/claude-code/bin/deckhand tabs 2>&1 || true)
case "$old" in
  *"not inside a Deckhand Claude tab"*|"") echo "FAILED: bin/deckhand with only the old names: $old"; fail=1 ;;
  *) echo "ok: bin/deckhand runs the CLI from PI_DESK_CLI, which reads PI_DESK_SOCKET" ;;
esac
if [ $fail = 1 ]; then echo "claude scene failed (logs: $W)"; exit 1; fi
echo "claude scene ok"
