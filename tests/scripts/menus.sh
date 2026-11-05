#!/bin/sh
# Every right-click menu, row by row, in test mode (tests/scripts/menus.txt):
# each row's effect, or the toast that says why it could not. Session rows
# (Open group, listing, ⓘ), sort menus, project rows, the "+" menu, the Files
# tab, the editor, the worktree switcher, the Settings tab, a job row.
# Fixtures: a fake HOME and pi store (a session file WITH pi-subagents'
# same-named folder beside it, a session without a header), a git project
# with a worktree and files, a notes folder with one job, a fake pi for
# project tabs and fake Atlas (tests/scripts/fake-atlas.py), a temp data dir.
# Never the user's ~/.pi, data dir or notes. Usage: tests/scripts/menus.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
. tests/scripts/claude-stub.sh
W="$ROOT/build/menus"
rm -rf "$W" build/shots/menus
FAKE_HOME="$W/home"
claude_stub "$FAKE_HOME" # Claude Code "installed": the menus read as with it (docs/CLAUDE.md §1)
STORE="$FAKE_HOME/.pi/agent/sessions"
A="$FAKE_HOME/code/alpha"
B="$FAKE_HOME/code/bravo"
NOTES="$FAKE_HOME/notes"
mkdir -p "$STORE" "$W/data" "$A" "$B/.git" "$NOTES/jobs" "$FAKE_HOME/bin"

# session DIR CWD HOURS-AGO ID TITLE (mtime HOURS-AGO; the file name's time
# fixed: the order a folder listing returns is then the same every run, and
# b1's subagents folder comes before its file, as pi-desk lists the folder)
session() {
  d="$STORE/$1"; mkdir -p "$d"
  ts="2026-10-$((23 - $3))T10-00-00-000Z"
  sf="$d/${ts}_$4.jsonl"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s","timestamp":"2026-10-30T10:00:00.000Z"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' \
    "$4" "$2" "$5" > "$sf"
  touch -t "$(date -v-"$3"H +%Y%m%d%H%M.%S)" "$sf"
  echo "$sf"
}
session --code-alpha-- "$A" 1 a1 "Alpha work" > /dev/null
f=$(session --code-bravo-- "$B" 2 b1 "Subagents ran here")
# pi-subagents' folder beside it: same name without .jsonl, a run inside
mkdir -p "${f%.jsonl}/run-1"; printf '{}\n' > "${f%.jsonl}/run-1/meta.json"
session --code-bravo-- "$B" 3 b2 "Plain session" > /dev/null
# a session file whose first line is not a session header
g=$(session --code-bravo-- "$B" 4 b3 "No header")
printf '{"type":"message","message":{"role":"user","content":"No header"}}\n' > "$g"
touch -t "$(date -v-4H +%Y%m%d%H%M.%S)" "$g"

# alpha: a git repository with a worktree (branch feature) and a few files
printf 'hello\nworld\n' > "$A/a.txt"
printf '# Notes\n\nSome text.\n' > "$A/notes.md"
mkdir -p "$A/sub"; printf 'x\n' > "$A/sub/x.txt"
git -C "$A" init -q -b main
git -C "$A" -c user.name=t -c user.email=t@example.invalid add -A
git -C "$A" -c user.name=t -c user.email=t@example.invalid commit -q -m init
git -C "$A" worktree add -q -b feature "$FAKE_HOME/code/alpha-wt"
printf 'hello\nworld\nchanged\n' > "$A/a.txt"

# pi's own config (the Settings tab): settings.json and a prompt
mkdir -p "$FAKE_HOME/.pi/agent/prompts"
printf '{}\n' > "$FAKE_HOME/.pi/agent/settings.json"
printf 'Fix it.\n' > "$FAKE_HOME/.pi/agent/prompts/fix.md"

# one job (a fake `pi --mode json` as pi)
cp tests/scripts/fake-pi-json.py "$FAKE_HOME/bin/pi"
chmod 755 "$FAKE_HOME/bin/pi"
printf -- '---\ntype: job\nproject: atlas\ndate: 2026-11-01\nstatus: active\nsummary: m1\ntags: [job]\nupdated_by: claude\nid: m1\nenabled: false\nschedule: "manual"\nnotify: always\nfolder: ~/code/alpha\naccess: read\n---\n# Job m1\n\n## Prompt\nOK\n' > "$NOTES/jobs/menu-job.md"

# Atlas's pi gets --append-system-prompt: the fake Atlas; anything else is a fake pi
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/menus.txt PI_DESK_DATA_DIR="$W/data" \
  PI_DESK_CMD="case \" \$* \" in *' --append-system-prompt '*) exec python3 -I '$ROOT/tests/scripts/fake-atlas.py' \"\$@\";; *) while [ \"\${1:-}\" = -e ]; do shift 2; done; echo \"ARGS: \$*\"; exec sleep 600;; esac" \
  build/deckhand > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|TIMEOUT|done:|no element|unknown command|toast:" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
[ -d "${f%.jsonl}/run-1" ] || { echo "the subagents folder was touched"; fail=1; }
if [ $fail = 1 ]; then echo "menus scene failed (log: $W/run.log)"; exit 1; fi
echo "menus scene ok"
