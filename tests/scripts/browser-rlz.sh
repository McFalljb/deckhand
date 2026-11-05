#!/bin/sh
# pi-desk's Chromium does not touch the Google Chrome files this test plants in
# a fake home (docs/BROWSER.md §2.3): the home-folder
# Google paths the CEF framework's strings name, which are RLZ's
# ~/Library/Application Support/Google/RLZ/RlzStore.plist (Google's
# brand/promotion tracker), the Mac brand file ~/Library/Google/Google Chrome
# Brand.plist, Chrome Cloud Enrollment's folder and Google/Skia (under both
# Application Support and Caches), plus Google Chrome's own Local State. The
# shim sends the framework's user Library lookups to <data dir>/browser/home/
# Library, and the app's KSBrandID ("", organic) ends the brand lookup before
# it reaches the home folder. Not covered: paths the framework does not name,
# and the system-wide /Library/Google files (outside the home folder).
# A fake home stands in for the real one (CFFIXED_USER_HOME, so macOS's Library
# lookups and ~ land there) with sentinel files whose access times are older
# than their modification times: any read moves the access time, and listing
# a sentinel's folder moves the folder's. A page idles 100 s in test mode
# (offline; an RLZ ping was once seen about 80 s in).
# Fails if a sentinel or its folder is read or changed, or gets a file beside
# it, or if RLZ's store is not in pi-desk's own folder, or if an RLZ ping was
# tried. Needs a CEF build. Writes build/browser-rlz.noindex/. About 2 minutes.
# Usage: tests/scripts/browser-rlz.sh   (RLZ_DIR=... to run two at once)
set -eu
unset CLAUDE_CONFIG_DIR # never the user's own Claude Code folder (a Claude Code session sets one)
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
. tests/scripts/fresh-build.sh
# .noindex: Spotlight would read the sentinels (and move their access times)
W="${RLZ_DIR:-$ROOT/build/browser-rlz.noindex}"
rm -rf "$W"; FAKE_HOME="$W/home"; PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--"
printf '{"type":"session","version":3,"id":"rrrr-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_rrrr-1.jsonl"
L="$FAKE_HOME/Library"
SENTINELS="$L/Application Support/Google/RLZ/RlzStore.plist
$L/Google/Google Chrome Brand.plist
$L/Application Support/Google/Chrome Cloud Enrollment/dmtoken
$L/Application Support/Google/Skia/sentinel
$L/Caches/Google/Skia/sentinel
$L/Application Support/Google/Chrome/Local State"
# stamps: each sentinel's and its folder's atime mtime ctime (stat only: no reads)
stamps() {
  echo "$SENTINELS" | while IFS= read -r f; do
    echo "$f: $(stat -f '%a %m %z' "$f") | folder $(stat -f '%a %m %z' "$(dirname "$f")")"
  done
}
# listings: what is in each sentinel's folder (a read: take it before setting times, after checking them)
listings() { echo "$SENTINELS" | while IFS= read -r f; do echo "$(dirname "$f"): $(ls -a "$(dirname "$f")" | tr '\n' ' ')"; done; }
echo "$SENTINELS" | while IFS= read -r f; do
  mkdir -p "$(dirname "$f")"
  plutil -create xml1 "$f"
done
before_ls=$(listings)
echo "$SENTINELS" | while IFS= read -r f; do
  d=$(dirname "$f")
  touch -m -t 202001010000 "$f" "$d"
  touch -a -t 201901010000 "$f" "$d"
done
before=$(stamps)
HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/browser-rlz.txt \
  PI_DESK_DATA_DIR="$W/data" PI_DESK_CEF_NETLOG="$W/netlog.json" PI_DESK_CMD='exec sleep 600' \
  build/deckhand "$PROJ" > "$W/run.log" 2>&1 || true
fail=0
grep -q "done: .* 0 failed" "$W/run.log" || { echo "rlz: the scene failed (log: $W/run.log)"; fail=1; }
after=$(stamps); after_ls=$(listings)
if [ "$before" != "$after" ]; then
  echo "rlz FAILED: a shared Google file or its folder was read or changed (atime mtime ctime, before/after):"
  printf '%s\n' "$before" > "$W/before.txt"; printf '%s\n' "$after" > "$W/after.txt"
  diff "$W/before.txt" "$W/after.txt" | sed -n 's/^[<>] /  /p'
  fail=1
fi
[ "$before_ls" = "$after_ls" ] || { echo "rlz FAILED: files appeared beside a sentinel:"; echo "$after_ls" | sed 's/^/  /'; fail=1; }
OWN="$W/data/browser/home/Library/Application Support/Google/RLZ"
[ -d "$OWN" ] || { echo "rlz FAILED: RLZ's store is not in pi-desk's folder ($OWN)"; fail=1; }
if grep -q "clients1.google.com" "$W/netlog.json" 2>/dev/null; then echo "rlz FAILED: the RLZ ping was tried (clients1.google.com)"; fail=1; fi
[ $fail = 0 ] && echo "rlz ok" || exit 1
