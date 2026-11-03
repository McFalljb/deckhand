#!/bin/sh
# The Changes tab end to end in test mode: a fake HOME with a git project on
# a branch one commit ahead of main, with a modified, a staged, an added, a
# deleted, a renamed and an untracked file and a .env (listed, never shown),
# a fake pi, a temp data dir (never the user's).
#   the "±" button and its count, the list and diffs, j/k, Open at the hunk,
#   stage and unstage, discard (confirmed; an untracked file twice, to the
#   Trash), commit with the user's pre-commit hook, Merge disabled, light
#   and dark, idle CPU
# Screenshots go to build/shots/changes/. Usage: tests/scripts/changes.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/changes"
rm -rf "$W" build/test-trash
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ/src" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"cccc-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_cccc-1.jsonl"
g() { HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 git -c init.defaultBranch=main "$@"; }
(cd "$PROJ" && g init -q && g config user.name t && g config user.email t@example.invalid && g config commit.gpgsign false)
printf 'int add(int a, int b) {\n    return a + b;\n}\n\nint sub(int a, int b) {\n    return a - b;\n}\n' > "$PROJ/src/a.c"
printf '# proj\n\nA small project.\n' > "$PROJ/README.md"
printf 'gone\n' > "$PROJ/gone.txt"
printf 'rename me\nkeep these lines\nso git sees a rename\n' > "$PROJ/old.txt"
(cd "$PROJ" && g add . && g commit -qm init && g branch -M main)
(cd "$PROJ" && g checkout -q -b feature && printf 'feature\n' > f.txt && g add f.txt && g commit -qm "feature work")
printf 'int add(int a, int b) {\n    return a + b; // checked\n}\n\nint sub(int a, int b) {\n    return a - b;\n}\n\nint mul(int a, int b) {\n    return a * b;\n}\n' > "$PROJ/src/a.c"
printf '# proj\n\nA small project, now staged.\n' > "$PROJ/README.md"
printf 'added\n' > "$PROJ/added.txt"
(cd "$PROJ" && g add README.md added.txt && g rm -q gone.txt && g mv old.txt new.txt)
printf 'notes\nmore notes\n' > "$PROJ/notes.txt"
printf 'TOKEN=not-a-real-secret\n' > "$PROJ/.env"
# the user's pre-commit hook: a user-initiated commit runs it
mkdir -p "$PROJ/.git/hooks"
printf '#!/bin/sh\ntouch "%s/pre-commit-ran"\n' "$W" > "$PROJ/.git/hooks/pre-commit"
chmod +x "$PROJ/.git/hooks/pre-commit"
run() { # script log
  HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 SHELL=/bin/sh PI_DESK_SCRIPT="$1" PI_DESK_DATA_DIR="$W/data" \
    PI_DESK_CMD='echo "ARGS: $*"; exec sleep 600' build/pi-desk > "$2" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU" "$2" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$2" || ! grep -q "done:" "$2"; then
    echo "changes scene failed (log: $2)"; exit 1
  fi
}
echo "== changes: list, diffs, stage/unstage, discard, commit"
run tests/scripts/changes.txt "$W/run.log"
test -e "$W/pre-commit-ran" || { echo "the pre-commit hook did not run"; exit 1; }
test ! -e "$PROJ/notes.txt" || { echo "the untracked file is still there"; exit 1; }
ls build/test-trash | grep -q notes.txt || { echo "notes.txt is not in the test trash"; exit 1; }
grep -q 'return a + b;$' "$PROJ/src/a.c" || { echo "src/a.c was not discarded"; exit 1; }
[ "$(cd "$PROJ" && g log -1 --format=%s)" = "Stage, rename and add from the Changes tab" ] || { echo "not committed"; exit 1; }
[ "$(cd "$PROJ" && g rev-list --count main..HEAD)" = 2 ] || { echo "the branch is not 2 ahead"; exit 1; }
echo "changes scene ok"
