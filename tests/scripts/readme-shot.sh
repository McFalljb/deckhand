#!/bin/sh
# The README's clip and screenshot (docs/images/deckhand-demo.gif, deckhand.png):
# demo data only. A fake HOME with three made-up projects and a few chats, a demo
# pi that draws a made-up conversation and publishes a todos panel
# (tests/scripts/demo-pi.py, never a real pi), a Markdown tab dragged into a split
# and a browser tab on a local test page (tests/web/demo.html); dark graphite,
# 1400x860. The clip's frames are Deckhand's own `shot`s of its hidden test
# window (readme-shot.txt: readme/frames/NN-MS shows for MS ms), joined by ffmpeg.
# Needs a CEF build (./build.sh) and ffmpeg. Writes build/shots/readme/deckhand.png,
# deckhand-demo.gif and deckhand-demo.mp4; copy them to docs/images/ after
# checking them by eye.
# Captures use `screencapture -l` of the test window, so the app that runs this
# script (a terminal) needs Screen Recording permission; from inside a Deckhand
# tab that means Deckhand itself, else every frame fails ("could not create image").
# Usage: tests/scripts/readme-shot.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
export DECKHAND_SCALE=${DECKHAND_SCALE:-2} # rendered at 2x as on a Retina Mac; `shot` (screencapture) still records at the real display's scale
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/readme-shot"
rm -rf "$W" build/shots/readme
FAKE_HOME="$W/home"
STORE="$FAKE_HOME/.pi/agent/sessions"
mkdir -p "$STORE" "$W/data" "$FAKE_HOME/Chats"

# session CWD HOURS-AGO ID TITLE
session() {
  name=$(printf '%s' "$1" | sed 's|^/||; s|/|-|g')
  d="$STORE/--$name--"
  mkdir -p "$d" "$1"
  ts=$(date -u -v-"$2"H +%Y-%m-%dT%H-%M-%S-000Z)
  f="$d/${ts}_$3.jsonl"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n' "$3" "$1" > "$f"
  printf '{"type":"message","message":{"role":"user","content":"%s"}}\n' "$4" >> "$f"
  touch -t "$(date -v-"$2"H +%Y%m%d%H%M.%S)" "$f"
}
P="$FAKE_HOME/code"
session "$P/recipe-box" 1 r1 "Import recipes from a CSV export"
session "$P/recipe-box" 5 r2 "Why does the search index miss accents?"
session "$P/recipe-box" 30 r3 "Add a shopping list view"
session "$P/recipe-box" 70 r4 "Paginate the search results"
session "$FAKE_HOME/garden-planner" 20 g1 "Frost dates per planting zone"
session "$FAKE_HOME/garden-planner" 90 g2 "Companion planting table"
session "$FAKE_HOME/notes" 200 n1 "Weekly review template"
CH=$(cd "$FAKE_HOME/Chats" && pwd -P)
session "$CH" 2 c1 "What is the difference between a mutex and a semaphore?"
session "$CH" 26 c2 "Plan a weekend in Lisbon"
printf "PROMPT='%%F{blue}%%~%%f %%# '\n" > "$FAKE_HOME/.zshrc"
cat > "$P/recipe-box/README.md" <<'MD'
# recipe-box

A small web app for keeping recipes: search, tags, a shopping list and
imports from other apps.

## Importing

- **CSV**: one recipe per row, with a header row; ingredients separated by
  semicolons.
- **Paprika**: export as `.paprikarecipes` and drop the file on the window.

## Development

```sh
npm install
npm run dev     # http://localhost:5173
npm test
```
MD
(cd "$P/recipe-box" && git init -q && git add . \
  && git -c user.name=demo -c user.email=demo@example.invalid -c commit.gpgsign=false commit -qm init)

# the core and the demo pis outlive the window (sessions keep running): stop this run's ones
stop_left() { pkill -f "$ROOT/build/(Deckhand\.app|deckhand)|$ROOT/tests/scripts/demo-pi\.py" 2>/dev/null || true; }
trap stop_left EXIT
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/zsh DECKHAND_SCRIPT=tests/scripts/readme-shot.txt \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_BIN="$ROOT/build/deckhand" \
  DECKHAND_CMD="DEMO_LIVE=1 exec python3 -I '$ROOT/tests/scripts/demo-pi.py' \"\$@\"" \
  build/deckhand "$P/recipe-box" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "readme shot failed (log: $W/run.log)"; exit 1
fi

# the clip: each frame once, held for its MS (ffmpeg's concat list; -fps_mode vfr keeps the GIF small), 1280 px wide
FFMPEG=$(command -v ffmpeg || echo /opt/homebrew/bin/ffmpeg)
LIST="$W/frames.txt"
: > "$LIST"
last=
for f in build/shots/readme/frames/*.png; do
  ms=$(basename "$f" .png | sed 's/.*-//')
  printf "file '%s'\nduration %s\n" "$ROOT/$f" "$(awk -v m="$ms" 'BEGIN{printf "%.3f", m/1000}')" >> "$LIST"
  last=$f
done
printf "file '%s'\n" "$ROOT/$last" >> "$LIST" # the concat demuxer drops the last duration otherwise
VF="scale=1280:-2:flags=lanczos"
"$FFMPEG" -loglevel error -y -f concat -safe 0 -i "$LIST" -fps_mode vfr \
  -vf "$VF,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none:diff_mode=rectangle" \
  build/shots/readme/deckhand-demo.gif
"$FFMPEG" -loglevel error -y -f concat -safe 0 -i "$LIST" -vf "$VF,format=yuv420p" \
  -c:v libx264 -crf 26 -preset slow -movflags +faststart -an build/shots/readme/deckhand-demo.mp4
ls -l build/shots/readme
