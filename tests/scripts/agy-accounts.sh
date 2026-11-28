#!/bin/sh
# Antigravity accounts (src/core/agy_accounts.odin; GUIDE "Antigravity accounts") in quiet test
# mode, against a fake HOME and a temp data dir: never the user's ~/.gemini*, never agy, pi or
# Google. Three fake agy profiles found by stat (~/.gemini, agy's own default without a file
# sign-in: a file account, since the default account holds the keychain; ~/.gemini-work with a fake file sign-in, mode 000: stat only;
# ~/.config/gemini-lab), and one outside HOME picked on the first-run sheet's Antigravity step:
# one renamed, one unticked, the default chosen; Done writes accounts.json under its lock. Then
# Settings › Coding agents › Antigravity: the rows, Rename… and Scan again.
# Writes build/agy-accounts/ and build/shots/agy-accounts/. Needs ./build.sh.
# Usage: tests/scripts/agy-accounts.sh
set -eu
unset CLAUDE_CONFIG_DIR GEMINI_HOME XDG_CONFIG_HOME
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/agy-accounts"
rm -rf "$W" build/shots/agy-accounts
H="$W/home"
mkdir -p "$H/proj" "$W/data" "$H/.gemini/antigravity-cli" "$H/.gemini-work/antigravity-acp" "$H/.config/gemini-lab/antigravity-acp" "$W/outside/Team agy/antigravity-acp"
for d in "$H/.gemini/antigravity-cli" "$H/.gemini-work/antigravity-acp" "$H/.config/gemini-lab/antigravity-acp" "$W/outside/Team agy/antigravity-acp"; do printf 'fake-id\n' > "$d/installation_id"; done
printf '{"fake":"never read"}\n' > "$H/.gemini-work/antigravity-acp/acp_token.json"
chmod 000 "$H/.gemini-work/antigravity-acp/acp_token.json"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdag.XXXXXX") # a short runtime dir: the socket path must fit sun_path
env -u PI_KIT_NOTES_DIR HOME="$H" CFFIXED_USER_HOME="$H" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/agy-accounts.txt \
  DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_FIRST_RUN=1 DECKHAND_CMD='exec sleep 600' \
  build/deckhand "$H/proj" > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
fail=0
grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
chk() { if eval "$2"; then echo "ok: $1"; else echo "FAILED: $1"; fail=1; fi; }
lsq() { env -u CLICOLOR_FORCE -u CLICOLOR ls -A "$1" | LC_ALL=C sort | tr '\n' ' '; }
A="$W/data/antigravity/accounts.json"
chk "accounts.json written, 0600" '[ -f "$A" ] && [ "$(stat -f %Lp "$A")" = 600 ]'
chk "the default chosen, the rename, the removed folder" 'python3 -I -c "
import json,sys
o=json.load(open(sys.argv[1]))
a={x[\"name\"]:x for x in o[\"accounts\"]}
assert o[\"defaultAccount\"]==\"work\", o
assert a[\"work\"][\"label\"]==\"Research\", a
assert a[\"gemini\"][\"storage\"]==\"file\" and a[\"work\"][\"storage\"]==\"file\", a
assert \"lab\" not in a and sys.argv[2] in o[\"removedDirs\"], o
assert any(x.get(\"source\")==\"added\" and x[\"dir\"]==sys.argv[3] for x in o[\"accounts\"]), a
" "$A" "$H/.config/gemini-lab" "$W/outside/Team agy"'
chk "no lock or temp file left" '[ "$(lsq "$W/data/antigravity")" = "accounts.json " ]'
chk "the profiles untouched" '[ "$(lsq "$H/.gemini-work/antigravity-acp")" = "acp_token.json installation_id " ] && [ "$(lsq "$H/.gemini")" = "antigravity-cli " ] && [ "$(lsq "$W/outside/Team agy")" = "antigravity-acp " ]'
chk "the sign-in file never changed (mode 000: never read)" '[ "$(stat -f %Lp "$H/.gemini-work/antigravity-acp/acp_token.json")" = 0 ]'
chmod 600 "$H/.gemini-work/antigravity-acp/acp_token.json"
if [ $fail = 1 ]; then echo "agy-accounts scene failed (log: $W/run.log)"; exit 1; fi
echo "agy-accounts scene ok"
