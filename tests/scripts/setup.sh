#!/bin/sh
# The first-run sheet end to end in test mode (quiet), against a fake HOME, a
# fake vault and a temp data dir (never the user's notes, ~/.pi or home):
# ~/.pi/agent/AGENTS.md names a repo (README.md only) and a vault (sessions/
# and README.md): the vault is pre-filled; separate chats (~/Chats has a
# chat); Done makes sessions/, jobs/, memory/, atlas/ in the vault (not
# chats/), touches nothing else, writes ~/Chats/AGENTS.md; the Jobs tab
# writes a draft into the vault's jobs/; pi tabs get PI_KIT_NOTES_DIR=<vault>.
# A second start: no sheet, and the user's own PI_KIT_NOTES_DIR wins.
# Screenshots: build/shots/setup/.
# Usage: tests/scripts/setup.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/setup"
rm -rf "$W" build/shots/setup
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
VAULT="$FAKE_HOME/notes/agents-demo"
REPO="$FAKE_HOME/code/repo"
mkdir -p "$PROJ" "$W/data" "$VAULT/sessions" "$VAULT/projects" "$REPO" "$FAKE_HOME/bin" "$FAKE_HOME/Chats" \
  "$FAKE_HOME/.pi/agent/sessions/--proj--" "$FAKE_HOME/.pi/agent/sessions/--chats--"
printf '{"type":"session","version":3,"id":"pppp-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_pppp-1.jsonl"
printf '{"type":"session","version":3,"id":"cccc-1","cwd":"%s"}\n' "$FAKE_HOME/Chats" \
  > "$FAKE_HOME/.pi/agent/sessions/--chats--/2026-10-30T10-00-00-000Z_cccc-1.jsonl"
printf '# Notes rules\n' > "$VAULT/README.md"
printf 'a session note\n' > "$VAULT/sessions/2026-10-30-x.md"
printf '# repo\n' > "$REPO/README.md"
printf '# Global rules\n\n- Work in `%s` for the repo.\n- Notes live in `%s/`, shared with pi.\n' "$REPO" "$VAULT" > "$FAKE_HOME/.pi/agent/AGENTS.md"
cp tests/scripts/fake-pi-json.py "$FAKE_HOME/bin/pi"
chmod 755 "$FAKE_HOME/bin/pi"
CMD='printf "%s\n" "${PI_KIT_NOTES_DIR:-unset}" >> "$HOME/pi-env.txt"; echo "ARGS: $*"; exec sleep 600'
env -u PI_KIT_NOTES_DIR HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/setup.txt PI_DESK_DATA_DIR="$W/data" PI_DESK_FIRST_RUN=1 \
  PI_DESK_CMD="$CMD" build/pi-desk "$PROJ" > "$W/run.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run.log" || true
fail=0
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
chk() { if ! eval "$2"; then echo "FAILED: $1"; fail=1; fi; }
# a folder's entries on one line (no colours, whatever CLICOLOR_FORCE says; C sort order)
lsq() { env -u CLICOLOR_FORCE -u CLICOLOR ls -A "$1" | LC_ALL=C sort | tr '\n' ' '; }
for d in sessions jobs memory atlas; do chk "$d/ made in the vault" '[ -d "$VAULT/$d" ]'; done
chk "no chats/ in the vault (separate chats)" '[ ! -e "$VAULT/chats" ]'
chk "README.md untouched" '[ "$(cat "$VAULT/README.md")" = "# Notes rules" ]'
chk "the session note untouched" '[ "$(cat "$VAULT/sessions/2026-10-30-x.md")" = "a session note" ]'
chk "the vault: only the subfolders added" '[ "$(lsq "$VAULT")" = "README.md atlas jobs memory projects sessions " ]'
chk "the repo untouched" '[ "$(lsq "$REPO")" = "README.md " ]'
chk "pi's AGENTS.md untouched" 'grep -q "^- Notes live in" "$FAKE_HOME/.pi/agent/AGENTS.md" && [ "$(lsq "$FAKE_HOME/.pi/agent")" = "AGENTS.md sessions " ]'
chk "no ~/pi-desk" '[ ! -e "$FAKE_HOME/pi-desk" ]'
chk "the job draft in the vault" '[ -f "$VAULT/jobs/setup-check.md" ]'
chk "chat instructions" 'head -1 "$FAKE_HOME/Chats/AGENTS.md" | grep -qx "# Chats"'
chk "a new chat got PI_KIT_NOTES_DIR" 'grep -qx "$VAULT" "$FAKE_HOME/pi-env.txt"'
chk "saved" 'grep -q "\"home_dir\":\"$VAULT\"" "$W/data/workspace.json" && grep -q "\"setup_seen\":true" "$W/data/workspace.json"'
# second start: no sheet; the user's own PI_KIT_NOTES_DIR wins
mkdir -p "$W/theirs"
: > "$FAKE_HOME/pi-env.txt"
PI_KIT_NOTES_DIR="$W/theirs" HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/setup-2.txt PI_DESK_DATA_DIR="$W/data" PI_DESK_FIRST_RUN=1 \
  PI_DESK_CMD="$CMD" build/pi-desk "$PROJ" > "$W/run-2.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run-2.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run-2.log" || ! grep -q "done:" "$W/run-2.log"; then fail=1; fi
chk "theirs wins" 'grep -qx "$W/theirs" "$FAKE_HOME/pi-env.txt" && ! grep -qx "$VAULT" "$FAKE_HOME/pi-env.txt"'
if [ $fail = 1 ]; then echo "setup scene failed (log: $W/run.log, $W/run-2.log)"; exit 1; fi
echo "setup scene ok"
