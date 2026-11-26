#!/bin/sh
# scripts/check-scoped-kills.py refuses a kill that could reach the developer's own Deckhand: in a
# temporary tree a scoped pkill passes, and each unscoped pkill or killall makes it fail. Under a
# second; run by ./build.sh test.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/scopedkills.XXXXXX")
trap 'rm -rf "$T"' EXIT
CHECK="python3 -I $ROOT/scripts/check-scoped-kills.py --root $T"
mkdir -p "$T/tests/scripts"
cat > "$T/tests/scripts/ok.sh" <<'SH'
# a comment may say pkill -f deckhand
pkill -9 -f "deckhand-core hold --run $r" 2>/dev/null || true
pkill -9 -f "$W/via.sh" || true
pkill -f -- "--run $RUN2( |$)" || true
pkill -9 -P "$p" 2>/dev/null || true
pkill -9 -P 1 -f "$ROOT/tests/scripts/fake-pi.py" || true
SH
printf 'subprocess.run(["pkill", "-9", "-f", f"serve --run {dirs.run}"])\n' > "$T/tests/ok.py"
$CHECK > "$T/out" || { echo "check-scoped-kills-test: a clean tree failed:"; cat "$T/out"; exit 1; }
for bad in \
  'pkill -9 -f "deckhand-core-serve connect --from" 2>/dev/null || true' \
  'pkill -f "$ROOT/build/deckhand-core-serve connect" || true' \
  'pkill -f "$ROOT/build/(Deckhand\.app|deckhand)|$ROOT/tests/scripts/demo-pi\.py" || true' \
  'killall deckhand-core-serve' \
  'subprocess.run(["pkill", "-f", "deckhand-core"])'; do
  printf '%s\n' "$bad" > "$T/tests/scripts/bad.sh"
  if $CHECK > "$T/out"; then echo "check-scoped-kills-test: not refused: $bad"; exit 1; fi
  grep -q "bad.sh:1:" "$T/out" || { echo "check-scoped-kills-test: no line for: $bad"; cat "$T/out"; exit 1; }
done
rm "$T/tests/scripts/bad.sh"
echo "check-scoped-kills-test: ok"
