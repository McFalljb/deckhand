#!/bin/sh
# Links in a terminal tab in test mode (quiet: the window stays hidden): ⌘-hover,
# ⌘-click (default browser), ⇧⌘-click (a browser tab) and the right-click menu on an OSC 8 link, URLs in text
# (in brackets, soft-wrapped), a mail link and a refused javascript: target.
# Opening is never real: test mode logs the default browser's URL, and a
# browser tab opens without starting Chromium (no CFFIXED_USER_HOME).
# A fake HOME with one project and session, a fake pi, a temp data dir.
# Writes build/term-links/ and build/shots/term-links/.
# Usage: tests/scripts/term-links.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/term-links"
rm -rf "$W" build/shots/term-links
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"llll-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_llll-1.jsonl"
WS=$(printf 'w%.0s' $(seq 1 400))
{
  printf 'A \033]8;;https://example.com/osc8\033\\click-here\033]8;;\033\\ end\n'
  printf '(see https://example.com/plain?q=1).\n'
  printf '\033]8;;javascript:alert(1)\033\\bad-link\033]8;;\033\\\n'
  printf 'mail mailto:a@example.invalid\n'
  printf 'W https://example.com/%s ZEND\n' "$WS"
} > "$FAKE_HOME/links.txt"
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/term-links.txt DECKHAND_DATA_DIR="$W/data" \
  DECKHAND_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "term-links scene failed (log: $W/run.log)"; exit 1
fi
echo "term-links scene ok"
