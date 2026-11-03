#!/bin/sh
# Saved-workspace cost while pi works: a new chat (no session file yet) in a
# project with 3000 sessions in pi's store, its fake bridge reporting
# pi.status and a panel every second; persistence on (temp data dir).
# Prints CPU% and the workspace save checks/writes. Test mode only.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/persist-cpu"
rm -rf "$W"
PROJ="$W/home/code/app"
D="$W/home/.pi/agent/sessions/--$(printf '%s' "${PROJ#/}" | tr / -)--"
mkdir -p "$PROJ" "$D" "$W/data"
i=0
while [ $i -lt 3000 ]; do
  printf '{"type":"session","version":3,"id":"s%d","cwd":"%s"}\n' $i "$PROJ" > "$D/2026-10-01T00-00-00-000Z_s$i.jsonl"
  i=$((i + 1))
done
HOME="$W/home" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/persist-cpu.txt PI_DESK_DATA_DIR="$W/data" \
  PI_DESK_CMD="exec python3 '$ROOT/tests/scripts/fake-bridge-status.py'" \
  build/pi-desk "$PROJ" 2>&1 | grep -E "CPU|pi-desk:|done:"
