#!/bin/sh
# Screenshot scene for the looks (build/shots/looks/): a fake pi store with several
# projects and sessions, pi in a new chat, a shell tab, the confirmation bar and
# the rename field; every look in dark and light.
# Default: a fake pi (tests/scripts/fake-bridge.sh), script looks.txt.
# LOOKS_PI=real: real pi with the real HOME (for its login) on a cheap model,
# writing its session into the fake store, `--use-theme system` so it follows
# the terminal's light/dark; script looks-pi.txt.
# Usage: [LOOKS_PI=real] tests/scripts/looks.sh [SCRIPT]
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
export DECKHAND_SCALE=${DECKHAND_SCALE:-2} # rendered at 2x as on a Retina Mac; `shot` (screencapture) still records at the real display's scale
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
LOOKS_PI=${LOOKS_PI:-fake}
if [ "$LOOKS_PI" = real ]; then SCRIPT=${1:-tests/scripts/looks-pi.txt}; else SCRIPT=${1:-tests/scripts/looks.txt}; fi
FAKE_HOME="$ROOT/build/looks-home"
STORE="$FAKE_HOME/.pi/agent/sessions"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$STORE"

# session FILE-DIR NAME HOURS-AGO ID TITLE
session() {
  ts=$(date -u -v-"$3"H +%Y-%m-%dT%H-%M-%S-000Z)
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$4" "$FAKE_HOME/code/$2" > "$1/${ts}_$4.jsonl"
  printf '{"type":"message","message":{"role":"user","content":"%s"}}\n' "$5" >> "$1/${ts}_$4.jsonl"
  touch -t "$(date -v-"$3"H +%Y%m%d%H%M)" "$1/${ts}_$4.jsonl"
}
project() { mkdir -p "$FAKE_HOME/code/$1" "$STORE/--code-$1--"; }

project recipe-box
session "$STORE/--code-recipe-box--" recipe-box 30 a1 "Import recipes from a CSV export"
session "$STORE/--code-recipe-box--" recipe-box 72 a2 "Why does the search index miss accents?"
project pi-kit
session "$STORE/--code-pi-kit--" pi-kit 5 b1 "Pin pi and recommended packages in one list"
session "$STORE/--code-pi-kit--" pi-kit 50 b2 "Sidebar: right-hand column for subagents"
project notes
session "$STORE/--code-notes--" notes 200 c1 "Weekly review template"
project Deckhand
session "$STORE/--code-deckhand--" Deckhand 0 d1 "Design tokens and three looks"
session "$STORE/--code-deckhand--" Deckhand 3 d2 "Confirmation bar for closing a busy tab"
session "$STORE/--code-deckhand--" Deckhand 26 d3 "Tab host sketch: Tab_Display and Tab_Host"
session "$STORE/--code-deckhand--" Deckhand 98 d4 "Command layer by stable ids, inbox and replies"
session "$STORE/--code-deckhand--" Deckhand 400 d5 "Spike: libghostty-vt in an Odin window"

cat > "$FAKE_HOME/.zshrc" <<'RC'
PROMPT='%F{blue}%~%f %# '
RC

if [ "$LOOKS_PI" = real ]; then
  PI=$(command -v pi)
  REAL_HOME=$HOME
  export DECKHAND_REAL_PI=1 # test mode's opt-in to the real pi (docs/DEVELOPING.md "Test mode")
  CMD="HOME='$REAL_HOME' exec '$PI' --model opencode-go/deepseek-v4.1-flash --use-theme system --session-dir '$STORE/--code-deckhand--' \"\$@\""
else
  CMD="exec sh '$ROOT/tests/scripts/fake-bridge.sh' \"\$@\""
fi
HOME="$FAKE_HOME" SHELL=/bin/zsh DECKHAND_SCRIPT="$SCRIPT" DECKHAND_TEXT_SAMPLE="$ROOT/tests/scripts/text-sample.sh" \
  DECKHAND_BIN="$ROOT/build/deckhand" DECKHAND_CMD="$CMD" \
  build/deckhand "$FAKE_HOME/code/deckhand"
