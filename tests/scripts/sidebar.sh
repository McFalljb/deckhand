#!/bin/sh
# The left column end to end in test mode: a fake HOME and pi store, a fake pi
# that prints its arguments, a temp data dir (never the user's).
#   1. add a project with "+" (picker faked) and by dropping a folder, a new
#      chat in it, Chats, pin, sort, filter, hide, the Open group, dividers
#   2. relaunch with the same data dir: pins, sort, hidden items and widths back
# Screenshots go to build/shots/sidebar/. Usage: tests/scripts/sidebar.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/sidebar"
rm -rf "$W"
# the fake HOME under a short temp path, so a path dropped on the terminal
# stays on one line of the 88-column test terminal from any checkout (a long
# worktree path wraps it). /tmp is not a temp folder for this run's projects.
T=$(mktemp -d /tmp/pd.XXXX) || exit 1
FAKE_HOME=$(cd "$T" && pwd -P) || exit 1
# only ever the temp folder made here
trap 'case "$FAKE_HOME" in /private/tmp/pd.?*|/tmp/pd.?*) rm -rf "$FAKE_HOME" ;; esac' EXIT
export DECKHAND_TEMP_ROOTS=/nonexistent-temp-root
STORE="$FAKE_HOME/.pi/agent/sessions"
mkdir -p "$STORE" "$W/data" "$FAKE_HOME/code/brand-new" "$FAKE_HOME/code/dropped"

# session PROJECT HOURS-AGO ID TITLE (file name and mtime both HOURS-AGO)
session() {
  d="$STORE/--code-$1--"
  mkdir -p "$d" "$FAKE_HOME/code/$1" "$FAKE_HOME/code/$1/.git" # repositories: top-level rows (else a "code" group row)
  ts=$(date -u -v-"$2"H +%Y-%m-%dT%H-%M-%S-000Z)
  f="$d/${ts}_$3.jsonl"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' \
    "$3" "$FAKE_HOME/code/$1" "$4" > "$f"
  touch -t "$(date -v-"$2"H +%Y%m%d%H%M.%S)" "$f"
}
session alpha 30 a1 "Write the release notes"
session alpha 50 a2 "Bump the parser"
session bravo 2 b1 "Fix the flaky test"
session charlie 10 c1 "Draw the logo"

run() { # script
  HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$1" DECKHAND_DATA_DIR="$W/data" \
    DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand
}
fail=0
for n in 1 2; do
  echo "== run $n"
  run tests/scripts/sidebar-$n.txt > "$W/run$n.log" 2>&1 || fail=1
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element" "$W/run$n.log" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$W/run$n.log"; then fail=1; fi
done
[ $fail = 0 ] || { echo "sidebar scene failed (logs in $W)"; exit 1; }
echo "workspace.json:"; cat "$W/data/workspace.json"
