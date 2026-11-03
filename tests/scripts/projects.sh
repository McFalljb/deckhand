#!/bin/sh
# The Projects tree (src/project_tidy.odin) in test mode: a fake HOME shaped
# like a real one, a fake pi that prints its arguments and folder, a temp
# data dir. Repositories are top-level rows, sibling folders in
# ~/workspace/projects/_scratch share a group row inside projects, other subfolders nest
# under their project; every row lists only its own sessions; a temp and a
# missing folder are hidden until Show hidden; a nested session resumes in
# its own folder. Run 2 relaunches: the opened rows stay open.
# Screenshots go to build/shots/projects/. Usage: tests/scripts/projects.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/projects"
rm -rf "$W"
FAKE_HOME="$W/home"
STORE="$FAKE_HOME/.pi/agent/sessions"
mkdir -p "$STORE" "$W/data"

# session CWD HOURS-AGO ID TITLE [gone]: the folder is made unless "gone"
session() {
  name=$(printf '%s' "$1" | sed 's|^/||; s|/|-|g')
  d="$STORE/--$name--"
  mkdir -p "$d"
  [ "${5:-}" = gone ] || mkdir -p "$1"
  ts=$(date -u -v-"$2"H +%Y-%m-%dT%H-%M-%S-000Z)
  f="$d/${ts}_$3.jsonl"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' \
    "$3" "$1" "$4" > "$f"
  touch -t "$(date -v-"$2"H +%Y%m%d%H%M.%S)" "$f"
}
repo() { mkdir -p "$1/.git"; }
H="$FAKE_HOME"
P="$H/workspace/projects"
session "$P" 10 p1 "Look around the projects folder"
session "$P/webstore" 2 t1 "Store: fix the cart total"; repo "$P/webstore"
session "$P/dataloader" 7 bt1 "Loader: speed up import"; repo "$P/dataloader"
session "$P/data/training-data" 11 td1 "Clean the training data"
E="$P/_scratch"
session "$E/batch-run-1" 6 f1 "Plan the deep review"
session "$E/batch-run-1/try-C" 1 c1 "C: fast vs steady"
session "$E/batch-run-1/try-B" 14 b1 "B: second opinion"
session "$E/batch-run-1/A-long-review/fix2/fast-vs-steady" 15 w1 "Fix 2: the fast one"
session "$E/ev-b" 12 eb1 "Evidence B"
session "$E/ev-c" 13 ec1 "Evidence C"
session "$H/workspace/pi-kit" 8 k1 "pi-kit: desk tools"; repo "$H/workspace/pi-kit"
G="$H/github" # (beside ~/workspace/projects it would share a "workspace" group row)
session "$G" 4 g1 "Only github's own session"
session "$G/project1" 3 g11 "Project one work"; repo "$G/project1"
session "$G/project2" 9 g21 "Project two work"; repo "$G/project2"
session "$G/notes" 5 gn1 "Notes beside the repos"
session "$H" 20 h1 "A chat at home"
session "/tmp/pd-scene-tidy-run" 0 tmp1 "A throwaway run" gone
session "$H/code/unplugged" 3 u1 "On a drive that is gone" gone

fail=0
for n in 1 2; do
  HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/projects-$n.txt PI_DESK_DATA_DIR="$W/data" \
    PI_DESK_CMD='echo "ARGS: $* CWD=$(pwd)"; exec sleep 600' build/pi-desk > "$W/run$n.log" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element" "$W/run$n.log" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$W/run$n.log" || ! grep -q "done:" "$W/run$n.log"; then fail=1; fi
done
[ $fail = 0 ] || { echo "projects scene failed (logs in $W)"; exit 1; }
