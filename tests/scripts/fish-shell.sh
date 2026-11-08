#!/bin/sh
# A fish user's Deckhand (docs/DEVELOPING.md "Launch environment"): $SHELL is a fish stand-in
# (tests/scripts/fake-fish.sh) that refuses POSIX sh syntax as fish does. pi and Claude tabs must
# still start: Deckhand runs its own sh script (PI_TAB_CMD, CLAUDE_TAB_CMD, their stand-ins) with
# /bin/sh when the login shell is not a POSIX shell, never `fish -l -c '<sh script>'`. Shell tabs
# still open fish itself. A fake HOME, a fake pi and a fake claude; never a real one.
# Writes build/fish/ (run.log, fish.log) and build/shots/fish/.
# Usage: tests/scripts/fish-shell.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
. tests/scripts/claude-stub.sh
W="$ROOT/build/fish"
rm -rf "$W" build/shots/fish
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"fish-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_fish-1.jsonl"
claude_stub "$FAKE_HOME"
# named fish, as a real one is (Deckhand knows a shell by its name: shell_is_posix)
mkdir -p "$W/bin"
ln -s "$ROOT/tests/scripts/fake-fish.sh" "$W/bin/fish"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdf.XXXXXX")
fail=0
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL="$W/bin/fish" FAKE_FISH_LOG="$W/fish.log" \
  DECKHAND_SCRIPT=tests/scripts/fish-shell.txt DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
  DECKHAND_CMD='for a in "$@"; do case "$a" in --session-id) echo "FAKE PI STARTED";; esac; done; exec sleep 600' \
  DECKHAND_CLAUDE_CMD='case "$*" in *--plugin-dir*) echo "FAKE CLAUDE STARTED";; esac; exec sleep 600' \
  build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
rm -rf "$RUN"
grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then
  echo "FAILED (log: $W/run.log)"; fail=1
fi
# the shell tab still ran fish itself (interactive), and fish never got Deckhand's sh scripts
if ! grep -q "fish -c: (interactive)" "$W/fish.log" 2>/dev/null; then echo "FAILED: the shell tab did not start the login shell"; fail=1; fi
if grep -q 'exec sleep 600' "$W/fish.log" 2>/dev/null; then echo "FAILED: fish was handed a tab's sh script"; fail=1; fi
[ $fail = 0 ] && echo "fish-shell: ok"
exit $fail
