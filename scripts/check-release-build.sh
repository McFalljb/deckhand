#!/bin/sh
# A release build has no test hooks (docs/plans/background-core.md §5.3, "A genuine binary under
# attacker config"; src/test_hooks.odin): fails if any binary given holds the name of a hook's
# environment variable (src/test_hooks.odin's HOOK_ENV), `--print-token`, or the updater's test
# key. scripts/release.sh runs it on the app's executables; tests/scripts/release-checks.sh tests it.
# Usage: scripts/check-release-build.sh BINARY...   (run from anywhere; reads src/ next to it)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || { echo "usage: scripts/check-release-build.sh BINARY..." >&2; exit 2; }
NAMES=$(sed -n 's/^[[:space:]]*\.[A-Za-z_]*[[:space:]]*= "\(PI_DESK_[A-Z_]*\)",*$/\1/p' "$ROOT/src/test_hooks.odin")
# the list itself must be there: an empty one would pass anything
n=$(printf '%s\n' "$NAMES" | grep -c PI_DESK_ || true)
[ "$n" -ge 20 ] || { echo "check-release-build: found only $n hook names in src/test_hooks.odin (HOOK_ENV moved?)" >&2; exit 1; }
TEST_PUB=$(sed -n 's/^.*UPDATE_TEST_PUBLIC_KEY :: "\(.*\)"$/\1/p' "$ROOT/src/update_key.odin")
fail=0
for bin in "$@"; do
  [ -f "$bin" ] || { echo "check-release-build: no file $bin" >&2; fail=1; continue; }
  for s in $NAMES --print-token $TEST_PUB; do
    if LC_ALL=C grep -aqF -- "$s" "$bin"; then
      echo "check-release-build: $bin holds \"$s\": a test hook in a release build (build it with DECKHAND_RELEASE=1 ./build.sh)" >&2
      fail=1
    fi
  done
done
[ $fail = 0 ] || exit 1
echo "check-release-build: no test hooks in $# binar$( [ $# = 1 ] && echo y || echo ies)"
