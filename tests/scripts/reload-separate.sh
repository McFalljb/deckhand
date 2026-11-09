#!/bin/sh
# Hot reload with a separate core (DECKHAND_SEPARATE_CORE=1; docs/plans/background-core.md
# §10.3 M4-C): a fake pi (tests/scripts/fake-bridge-reload.py) at 1.4.0, pi updated to 1.5.0,
# Restart: the core restarts the tab on its session. Then an extension's file is edited: the
# window's watcher hears it, the core (which has none) gets it (Fs_Changed) and the reload bar
# comes. The window process runs no core work (the replica check in run_command fails the run),
# and the fake bridge started twice, by the core.
# A fake HOME, a temp data dir and a short runtime dir; the core is stopped at the end.
# Usage: tests/scripts/reload-separate.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/reload-separate"
rm -rf "$W"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkrs.XXXXXX") # core.sock's path must fit in sun_path
cores() { pgrep -f "deckhand-core-serve serve --run $RUN" || true; }
cleanup() {
  cp "$RUN/core.log" "$W/core.log" 2>/dev/null || true
  for p in $(cores); do kill -9 "$p" 2>/dev/null || true; done
  pkill -9 -f "deckhand-core hold --run $RUN" 2>/dev/null || true
  rm -rf "$RUN"
}
trap cleanup EXIT
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/code/recipe-box"
AD="$FAKE_HOME/.pi/agent"
DIR="$AD/sessions/--reload--"
mkdir -p "$PROJ" "$DIR" "$W/data" "$W/pi-pkg" "$AD/extensions/demo"
printf 'export default function () {}\n' > "$AD/extensions/demo/index.ts"
printf 'echo "// edited" >> %s\n' "$AD/extensions/demo/index.ts" > "$FAKE_HOME/edit-ext.sh"
printf '{"type":"session","version":3,"id":"aaaa-1","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"Import recipes"}}\n' \
  "$PROJ" > "$DIR/2026-10-21T01-00-00-000Z_aaaa-1.jsonl"
printf '{"name":"@earendil-works/pi-coding-agent","version":"1.4.0"}\n' > "$W/pi-pkg/package.json"
printf 'echo %s > %s\n' "'{\"name\":\"@earendil-works/pi-coding-agent\",\"version\":\"1.5.0\"}'" "$W/pi-pkg/package.json" > "$FAKE_HOME/bump.sh"
HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SEPARATE_CORE=1 DECKHAND_SCRIPT=tests/scripts/reload-separate.txt \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
  DECKHAND_PI_PACKAGE="$W/pi-pkg/package.json" RELOAD_LOG="$W/bridge.log" \
  DECKHAND_CMD="exec python3 '$ROOT/tests/scripts/fake-bridge-reload.py' \"\$@\"" \
  build/deckhand > "$W/run.log" 2>&1 || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|no element|BUG: the window process" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
grep -q "core: attached to pid" "$W/run.log" || { echo "the window did not attach to a separate core"; fail=1; }
s=$(grep -c "^start aaaa-1" "$W/bridge.log" 2>/dev/null || true)
echo "bridge aaaa-1: $s starts"
[ "$s" = 2 ] || fail=1
if [ $fail = 1 ]; then echo "reload-separate failed (log: $W/run.log)"; tail -20 "$W/run.log"; exit 1; fi
echo "reload-separate: ok"
