#!/bin/sh
# A session's own agents show the user files (tests/scripts/agent-show.txt; show_file, docs/PROTOCOL.md):
# a fake pi bridge (fake-bridge-show.py, caller panel) and a fake claude running the plugin's
# `deckhand show` (fake-claude.py) each show a .md (a Markdown tab) and a .txt (an editor tab) in
# their own session, right after their own tab, behind the user's view; a file outside every
# project is shown; another session, a binary file are refused (code and hint). Never a real pi
# or claude. Quiet test mode, a fake HOME, a temp data dir. Needs ./build.sh (build/claude-code,
# build/deckhand-cli). Writes build/agent-show/ (run.log, show.log, claude.log).
# Usage: tests/scripts/agent-show.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
. tests/scripts/claude-stub.sh
[ -x build/deckhand-cli ] && [ -f build/claude-code/.claude-plugin/plugin.json ] || { echo "build/deckhand-cli or build/claude-code missing: ./build.sh"; exit 1; }
W="$ROOT/build/agent-show"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$W/data" "$PROJ/docs" "$FAKE_HOME/other" "$FAKE_HOME/outside"
printf '# Plan\n\nintro\n\n## Setup\n\nsteps\n' > "$PROJ/README.md"
printf 'one\ntwo\nthree\nfour\n' > "$PROJ/notes.txt"
printf '# Plan\n\n## Setup\n\nfrom Claude\n' > "$PROJ/docs/plan.md"
printf 'a\nb\nc\n' > "$PROJ/docs/todo.txt"
printf '\211PNG\r\n\032\n\000\000\000\rIHDR' > "$PROJ/logo.png"
printf 'other\n' > "$FAKE_HOME/other/notes.txt"
OUTSIDE="$FAKE_HOME/outside/sre-interview-questions.md"
printf '# SRE interview questions\n\n## Incidents\n' > "$OUTSIDE"
claude_stub "$FAKE_HOME"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pds.XXXXXX") # a short runtime dir: the socket path must fit sun_path
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/agent-show.txt DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_RUNTIME_DIR="$RUN" SHOW_LOG="$W/show.log" OUTSIDE_FILE="$OUTSIDE" \
  DECKHAND_CMD="exec python3 -I '$ROOT/tests/scripts/fake-bridge-show.py' \"\$@\"" \
  DECKHAND_CLAUDE_CMD="exec python3 -I '$ROOT/tests/scripts/fake-claude.py' \"\$@\"" \
  FAKE_CLAUDE_LOG="$W/claude.log" FAKE_CLAUDE_TURN_MS=100 \
  build/deckhand > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
want() { if grep -qE "$1" "$W/show.log" 2>/dev/null; then echo "ok: $2"; else echo "FAILED: $2 (no /$1/ in $W/show.log)"; fail=1; fi; }
want '^readme ok=True kind=markdown session=[0-9]+ again=False$' "pi: a .md opens in a Markdown tab"
want '^notes ok=True kind=editor session=[0-9]+ again=False$' "pi: a .txt opens in an editor tab"
want '^outside ok=True kind=markdown ' "pi: a file outside every project is shown"
want '^other sessions shown=0 codes=other_session$' "pi: every other session is refused"
want '^logo ok=False code=binary hint=True ' "pi: a binary file is refused with a hint"
want '^again ok=True kind=markdown session=[0-9]+ again=True$' "pi: shown again, the tab already open"
want '^same tab=True$' "pi: not opened twice"
# the fake claude's CLI calls (one JSON object a line)
python3 -I - "$W/claude.log" <<'PY' || fail=1
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1]) if l.strip().startswith("{")]
calls = [c for c in calls if "cli" in c]
def out(i):
    try:
        return json.loads(calls[i]["out"])
    except (IndexError, ValueError):
        return {}
ok = True
def check(cond, what):
    global ok
    print(("ok: " if cond else "FAILED: ") + what)
    ok = ok and cond
check(len(calls) == 3, "claude: three deckhand show calls (%d)" % len(calls))
a, b, c = out(0), out(1), out(2)
check(calls[0]["exit"] == 0 and a.get("kind") == "markdown" and "behind the user's view" in a.get("message", ""), "claude: a .md in a Markdown tab, behind the view")
check(calls[1]["exit"] == 0 and b.get("kind") == "editor", "claude: a .txt in an editor tab")
check(calls[2]["exit"] == 1 and c.get("code") == "binary" and c.get("hint"), "claude: a binary file refused with a code and a hint")
sys.exit(0 if ok else 1)
PY
if [ $fail = 1 ]; then echo "agent-show scene failed (logs: $W)"; exit 1; fi
echo "agent-show scene ok"
