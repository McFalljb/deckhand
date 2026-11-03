#!/bin/sh
# The Files tab's checkout switcher end to end in test mode: a fake HOME with
# a git project and its worktrees (one merged and clean, one dirty and ahead,
# one detached, one whose folder is gone), branches without a worktree
# (one merged, one ahead), a fake pi, a temp data dir (never the user's).
#   1. the switcher and its menu, picking a worktree (the tree shows it),
#      a terminal and a pi session in a worktree, Clean up through the
#      confirmation bar, light and dark, idle CPU
#   2. relaunch: the worktree session and the tree's checkout come back
# Screenshots go to build/shots/worktrees/. Usage: tests/scripts/worktrees.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/worktrees"
rm -rf "$W"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ/src" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"wwww-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_wwww-1.jsonl"
g() { HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@example.invalid \
  -c commit.gpgsign=false -c init.defaultBranch=main "$@"; }
printf '# proj\n' > "$PROJ/README.md"
printf 'node_modules/\ndist/\n.env*\n' > "$PROJ/.gitignore"
printf 'int app;\n' > "$PROJ/src/app.c"
(cd "$PROJ" && g init -q && g add . && g commit -qm init && g branch -M main)
# a branch without a worktree, one commit ahead; one merged
(cd "$PROJ" && g checkout -q -b topic && printf 't\n' > t.txt && g add t.txt && g commit -qm "topic work" && g checkout -q main && g branch lonely)
(cd "$PROJ" && g worktree add -q -b merged-wt "$FAKE_HOME/proj-a-merged")
mkdir -p "$FAKE_HOME/proj-a-merged/node_modules/pkg" "$FAKE_HOME/proj-a-merged/dist" # ignored: listed in the question
printf 'x\n' > "$FAKE_HOME/proj-a-merged/node_modules/pkg/index.js"
printf 'x\n' > "$FAKE_HOME/proj-a-merged/dist/app.js"
(cd "$PROJ" && g worktree add -q -b feature "$FAKE_HOME/proj-b-dirty")
(cd "$FAKE_HOME/proj-b-dirty" && printf 'f\n' > f.txt && g add f.txt && g commit -qm "feature work" \
  && printf 'changed\n' > README.md && printf 'new\n' > new.txt)
(cd "$PROJ" && g worktree add -q --detach "$FAKE_HOME/proj-c-detached" HEAD)
(cd "$PROJ" && g worktree add -q -b gone-wt "$FAKE_HOME/proj-d-gone")
rm -rf "$FAKE_HOME/proj-d-gone"
# a fake pi that prints its arguments; given --session-dir (a session in a
# worktree, kept with the project's) it writes the session file, as pi would
cat > "$W/fake-pi.sh" <<'PI'
echo "ARGS: $*"
d=""; i=""
while [ $# -gt 0 ]; do
  case "$1" in --session-dir) d=$2; shift ;; --session-id) i=$2; shift ;; esac
  shift
done
if [ -n "$d" ] && [ -n "$i" ]; then
  mkdir -p "$d"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$i" "$PWD" > "$d/2026-11-01T10-00-00-000Z_$i.jsonl"
fi
exec sleep 600
PI
run() { # script log
  HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 SHELL=/bin/sh PI_DESK_SCRIPT="$1" PI_DESK_DATA_DIR="$W/data" \
    PI_DESK_CMD="exec sh '$W/fake-pi.sh' \"\$@\"" build/pi-desk > "$2" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU" "$2" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$2" || ! grep -q "done:" "$2"; then
    echo "worktrees scene failed (log: $2)"; exit 1
  fi
}
echo "== run 1: switcher, menu, pick, terminal and pi session in a worktree, clean up"
run tests/scripts/worktrees-1.txt "$W/run1.log"
test ! -e "$FAKE_HOME/proj-a-merged" || { echo "the merged worktree is still there"; exit 1; }
if (cd "$PROJ" && g show-ref --verify -q refs/heads/merged-wt); then echo "merged-wt was not deleted"; exit 1; fi
test -d "$FAKE_HOME/proj-b-dirty" || { echo "the dirty worktree is gone"; exit 1; }
echo "== run 2: relaunch: the worktree session and the tree's checkout restored"
run tests/scripts/worktrees-2.txt "$W/run2.log"
