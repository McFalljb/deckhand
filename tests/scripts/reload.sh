#!/bin/sh
# Hot reload with a fake bridge (tests/scripts/fake-bridge-reload.py): a fake
# pi store with two sessions, a fake ~/.pi/agent, a fake pi package
# (PI_DESK_PI_PACKAGE) at 1.0.0, a temp data dir (never the user's). A shell
# tab edits pi's settings.json → the bar → Reload: pi.reload to the idle tab,
# the working one queued and reloaded once idle; an extension edit (FSEvents)
# while a tab has a background shell → the confirmation names it; a pi
# version bump → the restart offer → both tabs start again on their session;
# the gear's Reload all pi tabs; Later; light and dark; idle CPU with the bar up.
# Screenshots go to build/shots/reload/. Usage: tests/scripts/reload.sh [SCRIPT]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
SCRIPT=${1:-tests/scripts/reload.txt}
W="$ROOT/build/reload"
rm -rf "$W" build/shots/reload
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/code/recipe-box"
AD="$FAKE_HOME/.pi/agent"
DIR="$AD/sessions/--reload--"
mkdir -p "$PROJ" "$DIR" "$W/data" "$W/pi-pkg" "$AD/extensions/demo"
i=0
for s in "aaaa-1|Import recipes from a CSV export" "bbbb-2|Speed up the search index"; do
  id=${s%%|*}; title=${s#*|}; i=$((i + 1))
  printf '{"type":"session","version":3,"id":"%s","cwd":"%s"}\n{"type":"message","message":{"role":"user","content":"%s"}}\n' \
    "$id" "$PROJ" "$title" > "$DIR/2026-10-2${i}T0${i}-00-00-000Z_$id.jsonl"
done
printf '{\n  "defaultModel": "deepseek-v4.1-flash"\n}\n' > "$AD/settings.json"
printf 'export default function () {}\n' > "$AD/extensions/demo/index.ts"
printf '{"name":"@earendil-works/pi-coding-agent","version":"1.0.0"}\n' > "$W/pi-pkg/package.json"
# what the shell tab runs (typed into it by the script)
printf 'printf %s > %s\n' "'{\"defaultModel\": \"deepseek-v4.1-flash\", \"theme\": \"dark\"}'" "$AD/settings.json" > "$FAKE_HOME/edit-settings.sh"
printf 'printf %s > %s\n' "'{\"defaultModel\": \"kimi-k3\", \"theme\": \"dark\", \"lastChangelogVersion\": \"1.1.0\"}'" "$AD/settings.json" > "$FAKE_HOME/pi-writes.sh"
printf 'echo "// edited" >> %s\n' "$AD/extensions/demo/index.ts" > "$FAKE_HOME/edit-ext.sh"
printf 'echo %s > %s\n' "'{\"name\":\"@earendil-works/pi-coding-agent\",\"version\":\"1.1.0\"}'" "$W/pi-pkg/package.json" > "$FAKE_HOME/bump.sh"
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$SCRIPT" PI_DESK_DATA_DIR="$W/data" \
  PI_DESK_PI_PACKAGE="$W/pi-pkg/package.json" RELOAD_LOG="$W/bridge.log" \
  PI_DESK_CMD="exec python3 '$ROOT/tests/scripts/fake-bridge-reload.py' \"\$@\"" \
  build/pi-desk > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
# what the fake bridges saw: each tab reloaded twice, started again (restart), reloaded (the gear)
for id in aaaa-1 bbbb-2; do
  r=$(grep -c "^reload $id" "$W/bridge.log" || true); s=$(grep -c "^start $id" "$W/bridge.log" || true)
  w=$(grep -c "^wait_idle $id ok" "$W/bridge.log" || true)
  echo "bridge $id: $r reloads, $s starts, $w idle checks before the restart"
  [ "$r" = 3 ] && [ "$s" = 2 ] && [ "$w" = 1 ] || fail=1
done
if [ $fail = 1 ]; then echo "reload scene failed (log: $W/run.log)"; exit 1; fi
echo "reload scene ok"
