#!/bin/sh
# Real pi (your HOME, a cheap model) in a scratch project, playing
# tests/scripts/text-pi.txt. Usage: tests/scripts/text-pi.sh [BINARY]
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
BIN=${1:-build/deckhand}
mkdir -p build/pi-text-proj
rm -f build/test-data/workspace.json # start without a saved workspace
DECKHAND_SCRIPT=tests/scripts/text-pi.txt DECKHAND_REAL_PI=1 DECKHAND_DATA_DIR="$ROOT/build/test-data" \
  DECKHAND_CMD='pi --model opencode-go/deepseek-v4.1-flash "$@"' \
  "$BIN" "$ROOT/build/pi-text-proj"
