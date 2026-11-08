#!/bin/sh
# A session's own agent opens app tabs (tests/scripts/app-open.txt; docs/ENGINE-BRIDGE.md): a fake
# pi bridge (fake-bridge-apps.py, caller panel) opens its project's declared app by name in its
# own session, behind the user's view; naming another session, an argv, a command line or an
# undeclared name is refused; another session's app tab is never restarted, closed or called;
# its own restarts and closes. Quiet test mode, a fake HOME, a temp data dir. Needs
# build/fake-app (./build.sh test). Writes build/app-open/ (run.log, apps.log).
# Usage: tests/scripts/app-open.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
[ -x build/fake-app ] || { echo "build/fake-app missing: ./build.sh test (or ./build.sh fake-app)"; exit 1; }
W="$ROOT/build/app-open"
rm -rf "$W"
FAKE_HOME="$W/home"
mkdir -p "$W/data"
for p in proj other; do
  mkdir -p "$FAKE_HOME/$p/.deckhand"
  printf '{"apps":[{"name":"fake","argv":["%s/build/fake-app"]}]}\n' "$ROOT" > "$FAKE_HOME/$p/.deckhand/apps.json"
done
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdo.XXXXXX") # a short runtime dir: the socket path must fit sun_path
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/app-open.txt DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_RUNTIME_DIR="$RUN" APPS_LOG="$W/apps.log" DECKHAND_CMD="exec python3 -I '$ROOT/tests/scripts/fake-bridge-apps.py' \"\$@\"" \
  build/deckhand > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
want() { if grep -qE "$1" "$W/apps.log" 2>/dev/null; then echo "ok: $2"; else echo "FAILED: $2 (no /$1/ in $W/apps.log)"; fail=1; fi; }
want '^declared ok=True names=fake$' "app_declared lists its project's apps"
want '^open ok=True error=None$' "it opens at once: Deckhand asks nothing"
want '^opened tabs=1$' "the app tab opened in its own session"
want '^describe ok=True$' "the app it opened answers tab.describe"
want '^again ok=True$' "the same entry again opens another"
want '^again closed=True$' "and closes"
want '^shot1 ok=True visible=False$' "a screenshot of its hidden app tab"
want '^shot2 ok=True visible=False$' "and another"
want '^fresh=True$' "each a fresh frame"
want '^other sessions opened=0$' "naming any other session is refused"
want "^argv ok=False error=a pi or Claude tab opens only the apps its project declares" "an argv is refused"
want '^command ok=False$' "a command line is refused"
want '^nope ok=False error=no app "nope" in the session.s .deckhand/apps.json \(declared: "fake"\)$' "an undeclared name is refused, with the declared names"
want '^others acted=0$' "another session's tabs: no restart, close or call"
want '^restart ok=True$' "its own app tab restarts"
want '^describe again ok=True$' "and answers again"
want '^close ok=True$' "its own app tab closes"
if [ $fail = 1 ]; then echo "app-open scene failed (logs: $W)"; exit 1; fi
echo "app-open scene ok"
