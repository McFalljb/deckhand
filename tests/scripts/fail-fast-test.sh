#!/bin/sh
# A failed script line fails its scene: tests/scripts/panes.sh (one of the scene scripts that run
# the app with `|| true` and read its log) runs fail-fast-bogus.txt, whose dragtab names no tab,
# once stopping at the failure (DECKHAND_SCRIPT_FAIL_FAST=1, the default) and once running on
# (=0). Both runs must fail, and the stop must say where it stopped (docs/TESTING.md, "Failing fast").
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
LOG="$ROOT/build/fail-fast-bogus/run.log"
fail=0
for ff in 1 0; do
  if DECKHAND_SCRIPT_FAIL_FAST=$ff tests/scripts/panes.sh fail-fast-bogus.txt > "$ROOT/build/fail-fast-test-$ff.out" 2>&1; then
    echo "FAILED: a bogus dragtab passed its scene (DECKHAND_SCRIPT_FAIL_FAST=$ff; $LOG)"; fail=1
  else
    echo "ok: a bogus dragtab fails its scene (DECKHAND_SCRIPT_FAIL_FAST=$ff)"
  fi
  if [ $ff = 1 ]; then
    if ! grep -q "ASSERT FAILED (stopped at line 4 of tests/scripts/fail-fast-bogus.txt;" "$LOG"; then
      echo "FAILED: the stop does not say where it stopped ($LOG)"; fail=1
    fi
    if grep -q "done:" "$LOG"; then echo "FAILED: a stopped script logged done: ($LOG)"; fail=1; fi
    if grep -q "assert_state open_sessions" "$LOG"; then echo "FAILED: the script ran on after the failure"; fail=1; fi
  fi
done
[ $fail = 0 ] && echo "fail-fast-test: ok"
exit $fail
