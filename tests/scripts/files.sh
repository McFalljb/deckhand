#!/bin/sh
# The Files tab end to end in test mode: a fake HOME with a git project
# (modified, untracked and ignored files, a 10k-file folder), a fake pi that
# prints its arguments, a temp data dir (never the user's). Deleting goes to
# build/test-trash in test mode, never the user's Trash.
#   1. switch to Files, expand, open (preview, then kept), new file, rename
#      inline, delete with the confirmation bar, reveal the active file,
#      a change made outside shows up, drag a file onto a terminal, filter,
#      menus, the 10k-file folder while scrolling, idle CPU
#   2. relaunch: the Files tab and its open folders come back
# Screenshots go to build/shots/files/. Usage: tests/scripts/files.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/files"
rm -rf "$W" build/test-trash
# the fake HOME under a short temp path, so a path dropped on the terminal
# stays on one line of the 88-column test terminal from any checkout (a long
# worktree path wraps it). /tmp is not a temp folder for this run's projects.
T=$(mktemp -d /tmp/pd.XXXX) || exit 1
FAKE_HOME=$(cd "$T" && pwd -P) || exit 1
# only ever the temp folder made here
trap 'case "$FAKE_HOME" in /private/tmp/pd.?*|/tmp/pd.?*) rm -rf "$FAKE_HOME" ;; esac' EXIT
export PI_DESK_TEMP_ROOTS=/nonexistent-temp-root
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ/src" "$PROJ/node_modules/pkg" "$PROJ/huge" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"ffff-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_ffff-1.jsonl"
printf 'node_modules/\n*.log\n' > "$PROJ/.gitignore"
printf '# proj\n' > "$PROJ/README.md"
printf 'int main(void) {\n    return 0;\n}\n' > "$PROJ/main.c"
printf 'int app;\n' > "$PROJ/src/app.c"
printf 'int util;\n' > "$PROJ/src/util.c"
printf 'module.exports = 1;\n' > "$PROJ/node_modules/pkg/index.js"
(cd "$PROJ/huge" && i=0 && while [ $i -lt 10000 ]; do : > "f$i.txt"; i=$((i + 1)); done)
(cd "$PROJ" && git init -q && git add .gitignore README.md main.c src \
  && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm init)
printf 'int main(void) {\n    return 1;\n}\n' > "$PROJ/main.c" # modified
printf 'new\n' > "$PROJ/new.txt"                                # untracked
printf 'log\n' > "$PROJ/debug.log"                              # ignored
run() { # script log
  HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$1" PI_DESK_DATA_DIR="$W/data" \
    PI_DESK_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand > "$2" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU|FILES" "$2" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$2" || ! grep -q "done:" "$2"; then
    echo "files scene failed (log: $2)"; exit 1
  fi
}
echo "== run 1: the tree, files, git, drag, 10k folder"
run tests/scripts/files-1.txt "$W/run1.log"
echo "== run 2: relaunch: tab and open folders restored"
run tests/scripts/files-2.txt "$W/run2.log"
echo "test trash:"; ls build/test-trash
