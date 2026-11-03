#!/bin/sh
# Text-rendering screenshots: a fake HOME whose session titles mix emoji, CJK
# and long names, a fake pi, and a shell tab printing tests/scripts/text-sample.sh.
# Usage: tests/scripts/text-shots.sh SCRIPT [BINARY]   (shots land in build/shots/)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN=${2:-build/pi-desk}
FAKE_HOME="$ROOT/build/text-home"
PROJ="$ROOT/build/text-proj"
rm -rf "$FAKE_HOME" build/test-data
D="$FAKE_HOME/.pi/agent/sessions/--text--"
mkdir -p "$PROJ" "$D"
i=0
for title in "Fix the login bug 🐛 before release" "日本語のドキュメントを翻訳する" "Refactor → modules ✓ done" \
  "A very long session title that has to be clipped with an ellipsis at the end" "Café menu: naïve résumé"; do
  i=$((i + 1))
  f="$D/2026-10-30T1$i-00-00-000Z_tttt-$i.jsonl"
  printf '{"type":"session","version":3,"id":"tttt-%s","cwd":"%s"}\n' "$i" "$PROJ" > "$f"
  printf '{"type":"message","message":{"role":"user","content":"%s"}}\n' "$title" >> "$f"
done
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$1" \
  PI_DESK_CMD="sh '$ROOT/tests/scripts/text-sample.sh'; exec sleep 600" \
  "$BIN" "$PROJ"
