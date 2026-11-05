#!/bin/sh
# Atlas (pi-desk's agent) in its terminal drawer, in test mode: a fake HOME
# with one project, fake pis for project tabs, and a fake pi for Atlas
# (tests/scripts/fake-atlas.py: a pi-like screen and the pi integration's bridge over
# the socket). Screenshots go to build/shots/agent/.
# Usage: tests/scripts/agent.sh [SCRIPT]   (default tests/scripts/agent.txt)
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
SCRIPT=${1:-tests/scripts/agent.txt}
FAKE_HOME="$ROOT/build/agent-home"
PROJ="$FAKE_HOME/code/demo"
STORE="$FAKE_HOME/.pi/agent/sessions/--code-demo--"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$PROJ" "$STORE"
printf '{"type":"session","version":3,"id":"demo-1","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Fix the demo build"}}\n' "$PROJ" \
  > "$STORE/2026-10-30T10-00-00-000Z_demo-1.jsonl"
# Atlas's pi gets --append-system-prompt (only Atlas does): the fake Atlas; anything else is fake pi
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$SCRIPT" \
  PI_DESK_CMD="case \" \$* \" in *' --append-system-prompt '*) exec python3 -I '$ROOT/tests/scripts/fake-atlas.py' \"\$@\";; *) while [ \"\${1:-}\" = -e ]; do shift 2; done; echo \"ARGS: \$*\"; exec sleep 600;; esac" \
  build/deckhand "$PROJ"
