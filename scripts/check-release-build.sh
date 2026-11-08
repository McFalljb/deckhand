#!/bin/sh
# A release build has no test hooks (docs/plans/background-core.md §5.3, "A genuine binary under
# attacker config"; src/test_hooks.odin): fails if any binary given holds the name of a hook's
# environment variable (src/test_hooks.odin's HOOK_ENV), `--print-token`, the updater's test
# key, or any other `PI_DESK_…` name not in ALLOWED below (a knob added outside HOOK_ENV, such as
# a getenv in the CEF shim, is caught too). scripts/release.sh runs it on the app's executables;
# tests/scripts/release-checks.sh tests it.
# Usage: scripts/check-release-build.sh BINARY...   (run from anywhere; reads src/ next to it)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || { echo "usage: scripts/check-release-build.sh BINARY..." >&2; exit 2; }
NAMES=$(sed -n 's/^[[:space:]]*\.[A-Za-z_]*[[:space:]]*= "\(PI_DESK_[A-Z_]*\)",*$/\1/p' "$ROOT/src/test_hooks.odin")
# the list itself must be there: an empty one would pass anything
n=$(printf '%s\n' "$NAMES" | grep -c PI_DESK_ || true)
[ "$n" -ge 20 ] || { echo "check-release-build: found only $n hook names in src/test_hooks.odin (HOOK_ENV moved?)" >&2; exit 1; }
TEST_PUB=$(sed -n 's/^.*UPDATE_TEST_PUBLIC_KEY :: "\(.*\)"$/\1/p' "$ROOT/src/update_key.odin")

# The only PI_DESK_ names a release binary may hold. None is read to steer what Deckhand trusts,
# where its data lives or what it runs; each is one of:
#   the bare prefix: the env scrubs drop every inherited PI_DESK_* variable (login_env.odin,
#     app_tab.odin), and the embedded guide names `PI_DESK_*` (GUIDE.md, "Release builds")
#   what Deckhand gives its tabs and the CLIs read back as their transport, never read by the app
#     to change itself: SOCKET, TOKEN, CONTROL_TOKEN (pi and control; `deckhand --ctl` reads
#     SOCKET and TOKEN, as Settings › Copy a control token gives them), CLAUDE_TOKEN, CLAUDE_TAB,
#     CLAUDE_READONLY, CLAUDE_ACCOUNT (read by the tab's own launch shell), CLI, SHOTS_DIR
#     (pi-desk-cli reads SOCKET, CLAUDE_TOKEN and SHOTS_DIR: docs/CLAUDE.md)
#   set for an app tab (APP) and a job run (JOB, RUN, RUN_DIR, SCHEDULED_AT: docs/ATLAS.md)
#   the user's documented workarounds, read by the app: GUI_LAUNCH (=0 turns off the login-shell
#     environment import, docs/DEVELOPING.md) and CEF_SHARED_TEXTURE (=0 the slower CPU paint
#     path, docs/BROWSER.md); src/test_hooks.odin says why they stay
ALLOWED="PI_DESK_
PI_DESK_SOCKET
PI_DESK_TOKEN
PI_DESK_CONTROL_TOKEN
PI_DESK_CLAUDE_TOKEN
PI_DESK_CLAUDE_TAB
PI_DESK_CLAUDE_READONLY
PI_DESK_CLAUDE_ACCOUNT
PI_DESK_CLI
PI_DESK_SHOTS_DIR
PI_DESK_APP
PI_DESK_JOB
PI_DESK_RUN
PI_DESK_RUN_DIR
PI_DESK_SCHEDULED_AT
PI_DESK_GUI_LAUNCH
PI_DESK_CEF_SHARED_TEXTURE"
# a hook name may never be allowed (a slip here would hide one)
for s in $NAMES; do
  if printf '%s\n' "$ALLOWED" | grep -qxF -- "$s"; then
    echo "check-release-build: $s is both a hook (src/test_hooks.odin) and allowed here" >&2
    exit 1
  fi
done

fail=0
for bin in "$@"; do
  [ -f "$bin" ] || { echo "check-release-build: no file $bin" >&2; fail=1; continue; }
  for s in $NAMES --print-token $TEST_PUB; do
    if LC_ALL=C grep -aqF -- "$s" "$bin"; then
      echo "check-release-build: $bin holds \"$s\": a test hook in a release build (build it with DECKHAND_RELEASE=1 ./build.sh)" >&2
      fail=1
    fi
  done
  # the catch-all: every PI_DESK_ name in it (lower case too: no knob slips past as PI_DESK_x)
  for s in $(LC_ALL=C grep -aoE 'PI_DESK_[A-Za-z0-9_]*' "$bin" | LC_ALL=C sort -u); do
    printf '%s\n' "$ALLOWED" | grep -qxF -- "$s" && continue
    printf '%s\n' "$NAMES" | grep -qxF -- "$s" && continue # reported above
    echo "check-release-build: $bin holds \"$s\": not a hook in src/test_hooks.odin, nor allowed in scripts/check-release-build.sh (a test or development knob? compile it out of release builds)" >&2
    fail=1
  done
done
[ $fail = 0 ] || exit 1
echo "check-release-build: no test hooks in $# binar$( [ $# = 1 ] && echo y || echo ies)"
