#!/bin/sh
# A project's Files session (src/core/files_session.odin): with no session open, a click on a file
# in the Files tab opens it in the project's "Files" session (no agent: the fake pi never starts),
# and after a relaunch it is there again with its file tab.
# Fake HOME and pi, temp data dir. Usage: tests/scripts/files-session.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/files-session"
rm -rf "$W"
T=$(mktemp -d /tmp/pdfs.XXXX) || exit 1
FAKE_HOME=$(cd "$T" && pwd -P) || exit 1
trap 'case "$FAKE_HOME" in /private/tmp/pdfs.?*|/tmp/pdfs.?*) rm -rf "$FAKE_HOME" ;; esac' EXIT
export DECKHAND_TEMP_ROOTS=/nonexistent-temp-root
PROJ="$FAKE_HOME/notes"
mkdir -p "$PROJ" "$W/data"
printf 'alpha\n' > "$PROJ/a.txt"
printf '# B\n' > "$PROJ/b.md"
LOG="$W/run.log"
for n in 1 2; do
  sed "s|@PROJ@|$PROJ|g" "tests/scripts/files-session-$n.txt" > "$W/script-$n.txt"
  HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT="$W/script-$n.txt" DECKHAND_DATA_DIR="$W/data" \
    DECKHAND_CMD='echo "PI STARTED"; exec sleep 600' build/deckhand > "$LOG.$n" 2>&1 || true
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element" "$LOG.$n" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|PI STARTED" "$LOG.$n" || ! grep -q "done:" "$LOG.$n"; then
    echo "files-session scene failed (log: $LOG.$n)"; exit 1
  fi
done
echo "files-session scene passed"
