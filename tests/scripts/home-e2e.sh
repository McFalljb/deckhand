#!/bin/sh
# Atlas end to end with real pi in its terminal drawer, and Deckhand's pi
# integration it loads with -e (the bridge and the desk tools). Only
# Atlas is a real pi (real HOME for its login and packages, its session in
# build/test-data/home); project tabs are fake pis in a fake HOME, so what
# Atlas sees is the fake project. The model comes from pi-desk's setting
# agent_model (--model), its prompt from build/test-data/atlas/ATLAS.md
# (--append-system-prompt). Two short prompts: its name, then the projects
# (desk_state).
# Screenshots: build/shots/home/e2e-*. Log: build/home-e2e.log.
# Usage: tests/scripts/home-e2e.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
FAKE_HOME="$ROOT/build/home-e2e-home"
PROJ="$FAKE_HOME/code/demo"
STORE="$FAKE_HOME/.pi/agent/sessions/--code-demo--"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$PROJ" "$STORE"
printf '{"type":"session","version":3,"id":"demo-1","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Fix the demo build"}}\n' "$PROJ" \
  > "$STORE/2026-10-30T10-00-00-000Z_demo-1.jsonl"
PI=$(command -v pi)
REAL_HOME=$HOME
# Atlas's pi gets --append-system-prompt (only Atlas does): real pi; anything else is fake
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/home-e2e.txt PI_DESK_LOG_COMMANDS=1 PI_DESK_REAL_PI=1 \
  PI_DESK_CMD="case \" \$* \" in *' --append-system-prompt '*) HOME='$REAL_HOME' exec '$PI' \"\$@\";; *) while [ \"\${1:-}\" = -e ]; do shift 2; done; echo \"ARGS: \$*\"; exec sleep 600;; esac" \
  build/deckhand "$PROJ" > build/home-e2e.log 2>&1 || { tail -40 build/home-e2e.log; exit 1; }
grep -E "ASSERT|done:|TIMEOUT" build/home-e2e.log
echo "== control commands (the event log; tokens and text redacted)"
grep '^\[event\]' build/home-e2e.log | grep '"caller":"control"' | sed 's/^\[event\] //' | cut -c1-300
! grep -q "ASSERT FAILED\|TIMEOUT" build/home-e2e.log
