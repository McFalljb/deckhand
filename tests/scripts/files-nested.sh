#!/bin/sh
# The Files tree of a project that is not a repository, holding folders that
# are their own repositories (each with a commit) and also projects of their
# own in Deckhand, a plain folder, a symlinked folder and one that cannot be
# listed: every folder opens with a click, and the one that cannot be listed
# says why (with Retry).
# Fake HOME and pi, temp data dir. Usage: tests/scripts/files-nested.sh
set -eu
unset CLAUDE_CONFIG_DIR
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/files-nested"
rm -rf "$W"
T=$(mktemp -d /tmp/pdn.XXXX) || exit 1
FAKE_HOME=$(cd "$T" && pwd -P) || exit 1
trap 'chmod -R u+rwx "$FAKE_HOME" 2>/dev/null; case "$FAKE_HOME" in /private/tmp/pdn.?*|/tmp/pdn.?*) rm -rf "$FAKE_HOME" ;; esac' EXIT
export PI_DESK_TEMP_ROOTS=/nonexistent-temp-root
PROJ="$FAKE_HOME/gamedev"
mkdir -p "$PROJ/golf/src" "$PROJ/handmade/code" "$PROJ/plain" "$PROJ/locked" "$FAKE_HOME/elsewhere" "$W/data" \
  "$FAKE_HOME/.pi/agent/sessions/--gamedev--"
printf '{"type":"session","version":3,"id":"nnnn-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--gamedev--/2026-10-30T10-00-00-000Z_nnnn-1.jsonl"
printf 'int golf;\n' > "$PROJ/golf/src/golf.c"
printf 'int h;\n' > "$PROJ/handmade/code/h.c"
printf 'p\n' > "$PROJ/plain/p.txt"
printf 's\n' > "$PROJ/locked/s.txt"
printf 'e\n' > "$FAKE_HOME/elsewhere/e.txt"
ln -s "$FAKE_HOME/elsewhere" "$PROJ/linked"
for r in golf handmade; do
  (cd "$PROJ/$r" && git init -q && git add . \
    && git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm init)
done
chmod 000 "$PROJ/locked"
LOG="$W/run.log"
# the script names the project's folders: @PROJ@ is filled in
sed "s|@PROJ@|$PROJ|g" tests/scripts/files-nested.txt > "$W/script.txt"
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$W/script.txt" PI_DESK_DATA_DIR="$W/data" \
  PI_DESK_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' build/deckhand > "$LOG" 2>&1 || true
grep -E "ASSERT FAILED|done:|TIMEOUT|no element" "$LOG" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element" "$LOG" || ! grep -q "done:" "$LOG"; then
  echo "files-nested scene failed (log: $LOG)"; exit 1
fi
echo "files-nested scene passed"
