#!/bin/sh
# The first-run sheet end to end in test mode (quiet), against a fake HOME, a
# fake vault and a temp data dir (never the user's notes, ~/.pi or home):
# ~/.pi/agent/AGENTS.md names a repo (README.md only) and a vault (sessions/
# and README.md): the vault is pre-filled; separate chats (~/Chats has a
# chat); Done makes sessions/, jobs/, memory/, atlas/ in the vault (not
# chats/), touches nothing else, writes ~/Chats/AGENTS.md; the Jobs tab
# writes a draft into the vault's jobs/; pi tabs get PI_KIT_NOTES_DIR=<vault>.
# A second start: no sheet, and the user's own PI_KIT_NOTES_DIR wins.
# Then the Claude accounts step (two found plus one picked and one typed in by hand, one
# without Claude Code's files) and a home with one account (no step).
# Screenshots: build/shots/setup/.
# Usage: tests/scripts/setup.sh
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
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
CMD='printf "%s\n" "${PI_KIT_NOTES_DIR:-unset}" >> "$HOME/pi-env.txt"; while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600'
env -u PI_KIT_NOTES_DIR HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/setup.txt PI_DESK_DATA_DIR="$W/data" PI_DESK_FIRST_RUN=1 \
  PI_DESK_CMD="$CMD" build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
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
  PI_DESK_CMD="$CMD" build/deckhand "$PROJ" > "$W/run-2.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run-2.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run-2.log" || ! grep -q "done:" "$W/run-2.log"; then fail=1; fi
chk "theirs wins" 'grep -qx "$W/theirs" "$FAKE_HOME/pi-env.txt" && ! grep -qx "$VAULT" "$FAKE_HOME/pi-env.txt"'
# Claude Code accounts (claude_accounts.odin), never the user's own: a home with ~/.claude,
# ~/.claude-work and ~/.config/claude-personal (fake account files: stat only), a folder outside
# HOME for the picker, a folder without Claude Code's files typed in by hand
H2="$W/home2"
mkdir -p "$H2/proj" "$W/data2" "$H2/.claude" "$H2/.claude-work" "$H2/.config/claude-personal" "$W/outside/Team Claude" "$H2/plain-folder" "$H2/.claude-cache"
for d in "$H2/.claude" "$H2/.claude-work" "$H2/.config/claude-personal" "$W/outside/Team Claude"; do printf '{"fake":true}\n' > "$d/.claude.json"; done
env -u PI_KIT_NOTES_DIR -u XDG_CONFIG_HOME HOME="$H2" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/setup-accounts.txt PI_DESK_DATA_DIR="$W/data2" PI_DESK_FIRST_RUN=1 \
  PI_DESK_CMD="$CMD" build/deckhand "$H2/proj" > "$W/run-accounts.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run-accounts.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run-accounts.log" || ! grep -q "done:" "$W/run-accounts.log"; then fail=1; fi
chk "the accounts setting saved" 'grep -q "\"claude_account_default\":\"$H2/.claude-work\"" "$W/data2/workspace.json" && grep -q "\"removed\":true" "$W/data2/workspace.json" && grep -q "\"label\":\"Job\"" "$W/data2/workspace.json"'
chk "the account folders untouched" '[ "$(lsq "$H2/.claude-work")" = ".claude.json " ] && [ "$(lsq "$H2/plain-folder")" = "" ]'
# one account: no step
H3="$W/home3"
mkdir -p "$H3/proj" "$W/data3" "$H3/.claude"
printf '{"fake":true}\n' > "$H3/.claude/.claude.json"
env -u PI_KIT_NOTES_DIR -u XDG_CONFIG_HOME HOME="$H3" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/setup-one-account.txt PI_DESK_DATA_DIR="$W/data3" PI_DESK_FIRST_RUN=1 \
  PI_DESK_CMD="$CMD" build/deckhand "$H3/proj" > "$W/run-one.log" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run-one.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run-one.log" || ! grep -q "done:" "$W/run-one.log"; then fail=1; fi
if [ $fail = 1 ]; then echo "setup scene failed (log: $W/run.log, $W/run-2.log, $W/run-accounts.log, $W/run-one.log)"; exit 1; fi
echo "setup scene ok"
