#!/bin/sh
# scripts/fetch-cef.sh without the network (a temp cache seeded with archives):
#  1. an archive that fails the SHA-256 check is deleted and the fetch fails;
#  2. two fetches at once both succeed and leave one unpacked tree;
#  3. an unpacked tree whose archive changed afterwards is not reused: the fetch
#     fails (no network here), the archive and the tree's .ok stamp are gone.
# Needs the real archive in ~/Library/Caches/pi-desk/cef/downloads (cloned, cp -c).
# Usage: tests/scripts/fetch-cef-test.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
FILE=$(sed -n 's/^CEF_FILE_macosarm64=//p' vendor/cef/VERSION)
VERSION=$(sed -n 's/^CEF_VERSION=//p' vendor/cef/VERSION)
REAL="$HOME/Library/Caches/pi-desk/cef/downloads/$FILE"
[ -f "$REAL" ] || { echo "fetch-cef test: no cached archive ($REAL)"; exit 1; }
T="$ROOT/build/fetch-cef-test"
rm -rf "$T"; mkdir -p "$T/bad/downloads" "$T/race/downloads"
fail=0
# 1. a corrupt archive
echo "not a CEF archive" > "$T/bad/downloads/$FILE"
if PI_DESK_CEF_CACHE="$T/bad" scripts/fetch-cef.sh > "$T/bad.log" 2>&1; then echo "1: a corrupt archive was accepted"; fail=1; fi
if [ -f "$T/bad/downloads/$FILE" ]; then echo "1: the corrupt archive was kept"; fail=1; else echo "1: ok (corrupt archive deleted, fetch failed)"; fi
# 2. two fetches at once
cp -c "$REAL" "$T/race/downloads/$FILE"
PI_DESK_CEF_CACHE="$T/race" scripts/fetch-cef.sh > "$T/race1.log" 2>&1 & p1=$!
PI_DESK_CEF_CACHE="$T/race" scripts/fetch-cef.sh > "$T/race2.log" 2>&1 & p2=$!
wait $p1; r1=$?; wait $p2; r2=$?
D="$T/race/$VERSION/macosarm64"
if [ $r1 != 0 ] || [ $r2 != 0 ]; then echo "2: a concurrent fetch failed ($r1, $r2): $(cat "$T/race1.log" "$T/race2.log" | tr '\n' ' ')"; fail=1
elif [ ! -f "$D/.ok" ] || [ ! -f "$D/include/cef_version.h" ]; then echo "2: no complete tree"; fail=1
elif [ -n "$(ls -d "$D".* 2>/dev/null)" ]; then echo "2: leftovers: $(ls -d "$D".*)"; fail=1
else echo "2: ok (both succeeded, one tree)"; fi
# 3. the archive behind an unpacked tree changes
if [ -f "$D/.ok" ]; then
  printf x >> "$T/race/downloads/$FILE"
  if PI_DESK_CEF_CACHE="$T/race" scripts/fetch-cef.sh > "$T/tamper.log" 2>&1; then echo "3: a tree with a changed archive was reused"; fail=1
  elif [ -f "$T/race/downloads/$FILE" ] || [ -f "$D/.ok" ]; then echo "3: the changed archive or the tree's stamp was kept"; fail=1
  else echo "3: ok (changed archive deleted, tree not reused)"; fi
fi
rm -rf "$T"
[ $fail = 0 ] && echo "fetch-cef test ok" || { echo "fetch-cef test failed"; exit 1; }
