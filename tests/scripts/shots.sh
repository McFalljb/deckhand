#!/bin/sh
# Screenshot scene for the chrome's layout (build/shots/$OUT/, default
# ui-shots): the left column (Open, Projects with sessions, Chats), an editor
# tab with its toolbar, the Files tab, the settings popover and a narrow
# window, dark and light. Fake HOME, fake pi (prints its arguments), a temp
# data dir. Only commands and keys, so it runs against older builds too
# (before/after comparisons). Usage: [OUT=name] tests/scripts/shots.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
export DECKHAND_SCALE=${DECKHAND_SCALE:-2} # rendered at 2x as on a Retina Mac; `shot` (screencapture) still records at the real display's scale
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
OUT=${OUT:-ui-shots}
W="$ROOT/build/shots-scene"
rm -rf "$W"
FAKE_HOME="$W/home"
STORE="$FAKE_HOME/.pi/agent/sessions"
mkdir -p "$STORE" "$W/data" "$FAKE_HOME/Chats"

# session CWD HOURS-AGO ID TITLE ("" = no user message yet)
session() {
  name=$(printf '%s' "$1" | sed 's|^/||; s|/|-|g')
  d="$STORE/--$name--"
  mkdir -p "$d" "$1"
  ts=$(date -u -v-"$2"H +%Y-%m-%dT%H-%M-%S-000Z)
  f="$d/${ts}_$3.jsonl"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$3" "$1" > "$f"
  [ -n "$4" ] && printf '{"type":"message","message":{"role":"user","content":"%s"}}\n' "$4" >> "$f"
  touch -t "$(date -v-"$2"H +%Y%m%d%H%M.%S)" "$f"
}
P="$FAKE_HOME/code"
session "$P/recipe-box" 1 r1 "Import recipes from a CSV export"
session "$P/recipe-box" 5 r2 "Why does the search index miss accents in titles and ingredient names?"
session "$P/recipe-box" 30 r3 "Add a shopping list view"
session "$P/recipe-box" 50 r4 ""
session "$P/recipe-box" 70 r5 "Paginate the search results"
session "$P/recipe-box" 90 r6 "Dark mode for the print stylesheet"
session "$P/recipe-box" 120 r7 "Unit conversions: cups, grams, ounces"
session "$P/recipe-box" 140 r8 "Bump dependencies"
session "$P/recipe-box" 160 r9 "Fix the flaky import test"
session "$P/garden-planner-with-a-rather-long-folder-name" 20 g1 "Frost dates per planting zone"
session "$P/notes" 200 n1 "Weekly review template"
CH=$(cd "$FAKE_HOME/Chats" && pwd -P)
session "$CH" 2 c1 "What is the difference between a mutex and a semaphore?"
session "$CH" 26 c2 "Plan a weekend in Lisbon"
session "$CH" 72 c3 ""
# a small git project for the editor and Files tab
(cd "$P/recipe-box" && mkdir -p src && printf 'int main(void) {\n    return 0;\n}\n' > src/main.c \
  && printf '# recipe-box\n' > README.md && git init -q && git add . \
  && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm init \
  && printf 'int main(void) {\n    return 1;\n}\n' > src/main.c && printf 'x\n' > notes.txt)

sed "s|\$OUT|$OUT|g" tests/scripts/shots.txt > "$W/script.txt"
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$W/script.txt" DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand "$P/recipe-box" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "shots scene failed (log: $W/run.log)"; exit 1
fi
ls "build/shots/$OUT"
