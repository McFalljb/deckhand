#!/bin/sh
# Settings as files, end to end in test mode: a fake HOME with a fake
# ~/.pi/agent (settings.json with packages, models.json, an extension's
# config, and an auth.json holding a dummy secret), a fake pi that prints
# its arguments, a temp data dir (never the user's files).
# ⌘, and the gear show the left column's Settings tab: pi's files by an
# allowlist (never sessions/, npm/, logs…), the project's group with Create,
# the extensions; prompts/ opens like a Files folder; settings.json opens in
# an editor tab; invalid JSON is not saved; a valid save offers to reload
# pi; the row menu has no Rename/Trash for pi's config files; credential
# files are never shown (also inside an opened folder) or opened; the dummy
# secret never shows (not drawn, not in the log or pi-desk's data).
# Screenshots: build/shots/settings/.
# Usage: tests/scripts/settings.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/settings"
rm -rf "$W" build/shots/settings
FAKE_HOME="$W/home"
AD="$FAKE_HOME/.pi/agent"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$AD/sessions/--proj--" "$AD/extensions/subagent" "$AD/prompts" "$AD/npm" "$AD/bin" "$AD/logs"
printf '{"type":"session","version":3,"id":"ssss-1","cwd":"%s"}\n' "$PROJ" \
  > "$AD/sessions/--proj--/2026-10-30T10-00-00-000Z_ssss-1.jsonl"
printf '{\n  "defaultProvider": "anthropic",\n  "defaultModel": "claude-sonnet-5",\n  "packages": ["npm:pi-subagents@1.2.3"]\n}\n' > "$AD/settings.json"
# the dummy secret, put together so no file holds a whole key-shaped string;
# settings.txt and the leak check below look for its tail
SECRET="sk-""DUMMY-AUTH-SECRET"
printf '{"anthropic":{"type":"api_key","key":"%s"}}\n' "$SECRET" > "$AD/auth.json"
chmod 600 "$AD/auth.json"
printf '{"providers":{}}\n' > "$AD/models.json"
printf '# global instructions\n' > "$AD/AGENTS.md"
printf '{"compact": true}\n' > "$AD/extensions/subagent/config.json"
printf 'Fix the failing test.\n' > "$AD/prompts/fix.md"
printf '{"token":"%s"}\n' "$SECRET" > "$AD/prompts/token.json"
chmod 600 "$AD/prompts/token.json"
printf 'KEY=%s\n' "$SECRET" > "$AD/prompts/.env"
cp "$AD/settings.json" "$W/settings.before"
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/settings.txt PI_DESK_DATA_DIR="$W/data" \
  PI_DESK_CMD='echo "ARGS: $*"; exec sleep 600' build/pi-desk "$PROJ" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|CPU" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
# the dummy secret: never in the log (results, events) or pi-desk's data (the script's own line aside)
if grep -rh DUMMY-AUTH-SECRET "$W/run.log" "$W/data" | grep -v "assert_not_drawn\|assert ok: not drawn"; then echo "SECRET LEAKED"; fail=1; fi
cmp -s "$AD/settings.json" "$W/settings.before" || { echo "settings.json changed (an invalid save was written?)"; fail=1; }
grep -qF "$SECRET" "$AD/auth.json" || { echo "auth.json changed"; fail=1; }
grep -q '"theirs"' "$PROJ/.pi/settings.json" 2>/dev/null && { echo "Create wrote over a file"; fail=1; }
[ -f "$PROJ/.pi/settings.json" ] || { echo "Create made no .pi/settings.json"; fail=1; }
if [ $fail = 1 ]; then echo "settings scene failed (log: $W/run.log)"; exit 1; fi
echo "settings scene ok"
