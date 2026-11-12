#!/bin/sh
# Codex CLI tabs in quiet test mode (docs/CODEX.md): never a real codex. A fake codex
# (tests/scripts/fake-codex.py) checks the command line as Codex 0.167.2 reads it (--no-daemon, the
# hooks' TOML and their trust hashes, nothing that overrides the user's own settings), shows OSC 7501
# status, and runs Deckhand's hooks (build/deckhand-cli) lazily at the first prompt.
# Run 1 (codex-1.txt): + New session's picker lists Codex; its tab before the first prompt (OSC 7501
# only), its row once SessionStart came, a permission (the waiting mark, the bell), held prompts and
# their refusals, quit. Run 2 (codex-2.txt): the tab comes back and resumes (codex resume <id>);
# closed, Resume from its row. Run 3 (codex-3.txt): signed out (its bar until the login screen is
# answered). Run 4 (codex-4.txt): a Codex older than 0.163.0 is refused, with how to update.
# Then the fake's log is checked. Needs build/deckhand and build/deckhand-cli (./build.sh). Writes build/codex/ and build/shots/codex/.
# Usage: tests/scripts/codex.sh
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
W="$ROOT/build/codex"
rm -rf "$W" build/shots/codex
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
[ -x build/deckhand ] || { echo "codex scene: build/deckhand missing (./build.sh)"; exit 1; }
[ -x build/deckhand-cli ] || { echo "codex scene: build/deckhand-cli missing (./build.sh)"; exit 1; }
printf '{"type":"session","version":3,"id":"cccc-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_cccc-1.jsonl"
# Codex "installed" by npm (a stand-in package, never run: the tab runs the fake); its version from
# the package's package.json, as Deckhand reads it
codex_stub() { # DIR VERSION
  pkg="$1/lib/node_modules/@openai/codex"
  mkdir -p "$pkg/bin" "$1/bin"
  printf '{"name":"@openai/codex","version":"%s"}\n' "$2" > "$pkg/package.json"
  printf '#!/bin/sh\necho "stand-in codex (tests): never run" >&2\nexit 1\n' > "$pkg/bin/codex.js"
  chmod 755 "$pkg/bin/codex.js"
  ln -sf "$pkg/bin/codex.js" "$1/bin/codex"
}
codex_stub "$W/npm" 0.167.2
codex_stub "$W/npm-old" 0.160.0
LOG="$W/codex.log"
# the fake needs tomllib (Python 3.11+): this scene's python3, not the tab's login PATH's (macOS's 3.9)
PY=$(python3 -c 'import sys, tomllib; print(sys.executable)') || { echo "codex scene: python3 has no tomllib (3.11+ needed)"; exit 1; }
fail=0
for n in 1 2 3 4; do
  RUN=$(mktemp -d "${TMPDIR:-/tmp}/pdx.XXXXXX")
  extra="DECKHAND_CODEX_BIN=$W/npm/bin/codex"
  [ $n = 3 ] && extra="$extra FAKE_CODEX_SIGNED_OUT=1"
  [ $n = 4 ] && extra="DECKHAND_CODEX_BIN=$W/npm-old/bin/codex"
  env $extra HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh DECKHAND_SCRIPT=tests/scripts/codex-$n.txt \
    DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" DECKHAND_CMD='exec sleep 600' \
    DECKHAND_CODEX_CMD="exec '$PY' -I '$ROOT/tests/scripts/fake-codex.py' \"\$@\"" \
    FAKE_CODEX_LOG="$LOG" FAKE_CODEX_TOKEN_FILE="$W/tokens" FAKE_CODEX_SESSION=01a1d0d6-5353-7ff3-9308-ff91070ad530 FAKE_CODEX_TURN_MS=200 \
    build/deckhand > "$W/run$n.log" 2>&1 || true
  rm -rf "$RUN"
  grep -E "ASSERT FAILED|done:|TIMEOUT|unknown command|no element" "$W/run$n.log" | sed "s/^/run $n: /" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|unknown command|no element" "$W/run$n.log" || ! grep -q 'ui_command {"type":"quit","confirm"' "$W/run$n.log"; then
    echo "run $n: FAILED (log: $W/run$n.log)"; fail=1
  fi
done
# what the fake codex saw
python3 -I "$ROOT/tests/scripts/codex-check.py" "$LOG" || fail=1
# the tabs' tokens never reach what Deckhand writes: its output, logs, saved files
while read -r tok; do
  [ -z "$tok" ] && continue
  if grep -rqsF "$tok" "$W/run1.log" "$W/run2.log" "$W/run3.log" "$W/run4.log" "$W/data" "$LOG"; then echo "FAILED: a Codex tab's token in Deckhand's output or data"; fail=1; fi
done < "$W/tokens"
# Deckhand wrote nothing under the fake ~/.codex (it never existed)
if [ -e "$FAKE_HOME/.codex" ]; then echo "FAILED: something wrote $FAKE_HOME/.codex"; fail=1; else echo "ok: nothing under ~/.codex"; fi
[ $fail = 0 ] && echo "codex scene ok" || { echo "codex scene failed"; exit 1; }
