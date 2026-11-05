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
PI_DESK_SCRIPT=tests/scripts/text-pi.txt PI_DESK_REAL_PI=1 PI_DESK_DATA_DIR="$ROOT/build/test-data" \
  PI_DESK_CMD='pi --model opencode-go/deepseek-v4.1-flash "$@"' \
  "$BIN" "$ROOT/build/pi-text-proj"
