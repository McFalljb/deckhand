# Sourced by the scenes after `cd "$ROOT"`: they run build/deckhand as it is, so one built before
# the sources last changed (a merge or checkout since; ./build.sh test does not build it) would
# test an older Deckhand and fail in confusing ways ("not allowed for this caller"). Stop instead.
# What a build takes in: src/ (its own tests left out: they are not in the binary), the
# deckhand CLI (tools/pi-desk-cli) and the integrations it bundles (build.sh).
[ -x build/deckhand ] || { echo "build/deckhand missing: ./build.sh first"; exit 1; }
_stale=$(find src tools/pi-desk-cli integrations/claude-code integrations/pi/extensions integrations/pi/lib \
  integrations/pi/skills integrations/pi/extensions.json \
  -type f ! -name '*_test.odin' -newer build/deckhand 2>/dev/null | head -1)
[ -z "$_stale" ] || { echo "build/deckhand is older than $_stale: ./build.sh first"; exit 1; }
# a scene stops at its first failed check or wait (src/autotest.odin; PI_DESK_SCRIPT_FAIL_FAST=0
# to run every line anyway, e.g. to see all the failures of a script being written)
export PI_DESK_SCRIPT_FAIL_FAST="${PI_DESK_SCRIPT_FAIL_FAST:-1}"
