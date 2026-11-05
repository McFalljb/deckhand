#!/bin/sh
# Runs a test-mode script against a fake HOME with one pi project and session,
# and a fake pi that prints its arguments. Usage: tests/scripts/run.sh SCRIPT
# Writes build/p05-*.txt|json and build/test-data/commands.log.
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
FAKE_HOME="$ROOT/build/p05-home"
PROJ="$ROOT/build/p05-proj"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$PROJ" "$FAKE_HOME/.pi/agent/sessions/--p05--"
printf '{"type":"session","version":3,"id":"dddd-4","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--p05--/2026-10-30T10-00-00-000Z_dddd-4.jsonl"
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$1" \
  PI_DESK_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' \
  build/deckhand "$PROJ"
