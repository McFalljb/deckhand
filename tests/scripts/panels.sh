#!/bin/sh
# Panels and status dots with a fake bridge (tests/scripts/fake-bridge.sh):
# a fake pi store with three sessions, a fake pi per tab that publishes
# panels and pi.status over the socket. Screenshots go to build/shots/panels/.
# Usage: tests/scripts/panels.sh [SCRIPT]   (default tests/scripts/panels.txt)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SCRIPT=${1:-tests/scripts/panels.txt}
FAKE_HOME="$ROOT/build/panels-home"
PROJ="$FAKE_HOME/code/pi-desk" # inside the fake HOME: shows as ~/code/pi-desk
DIR="$FAKE_HOME/.pi/agent/sessions/--panels--"
rm -rf "$FAKE_HOME" build/test-data
mkdir -p "$PROJ" "$DIR"
i=0
for s in "aaaa-1|Rename the pi-kit sidebar settings" "bbbb-2|Which socket path should pi-desk use?" "cccc-3|Import recipes from a CSV export"; do
  id=${s%%|*}; title=${s#*|}; i=$((i + 1))
  f="$DIR/2026-10-3${i}T0${i}-00-00-000Z_$id.jsonl"
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' "$id" "$PROJ" "$title" > "$f"
done
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$SCRIPT" PI_DESK_BIN="$ROOT/build/pi-desk" \
  PI_DESK_CMD="exec sh '$ROOT/tests/scripts/fake-bridge.sh' \"\$@\"" \
  build/pi-desk ${PI_DESK_FAKE_MAX:+"$PROJ"}
