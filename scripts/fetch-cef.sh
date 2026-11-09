#!/bin/sh
# Fetch the pinned CEF distribution (vendor/cef/VERSION) into
# ~/Library/Caches/deckhand/cef/<version>/ and print that directory.
# Verifies SHA-256 before unpacking; a mismatch deletes the archive and stops
# (exit 1). Idempotent: an unpacked tree with a .ok stamp is reused without
# network access, but only while the archive it came from (kept in downloads/)
# still has the pinned SHA-256; otherwise it is fetched again. Safe to run
# concurrently (a lock per cache and arch).
# Usage: scripts/fetch-cef.sh [arch]   (arch: macosarm64 (default on arm64), macosx64)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PIN="$ROOT/vendor/cef/VERSION"
case "${1:-$(uname -m)}" in
  arm64|macosarm64) ARCH=macosarm64 ;;
  x86_64|macosx64)  ARCH=macosx64 ;;
  *) echo "fetch-cef: unknown arch ${1:-}" >&2; exit 1 ;;
esac
val() { sed -n "s/^$1=//p" "$PIN" | head -1; }
VERSION=$(val CEF_VERSION)
FILE=$(val "CEF_FILE_$ARCH")
SHA256=$(val "CEF_SHA256_$ARCH")
if [ -z "$VERSION" ] || [ -z "$FILE" ] || [ -z "$SHA256" ]; then
  echo "fetch-cef: $PIN has no pin for $ARCH" >&2; exit 1
fi
CACHE="${DECKHAND_CEF_CACHE:-$HOME/Library/Caches/deckhand/cef}"
# the cache's place before the rename (0.2.0): moved once, with a link back for older checkouts
OLD_CACHE="$HOME/Library/Caches/pi-desk/cef"
if [ -z "${DECKHAND_CEF_CACHE:-}" ] && [ ! -e "$CACHE" ] && [ -d "$OLD_CACHE" ] && [ ! -L "$OLD_CACHE" ]; then
  mkdir -p "$(dirname "$CACHE")"
  if mv "$OLD_CACHE" "$CACHE" 2>/dev/null; then
    ln -s "$CACHE" "$OLD_CACHE" 2>/dev/null || true
    echo "fetch-cef: moved the CEF cache from $OLD_CACHE to $CACHE" >&2
  fi
fi
DEST="$CACHE/$VERSION/$ARCH"
ARCHIVE="$CACHE/downloads/$FILE"
# the unpacked tree, while the archive beside it still checks out (a tampered or
# missing archive means the tree is not trusted: fetch, check and unpack again)
reusable() {
  [ -f "$DEST/.ok" ] && [ -f "$ARCHIVE" ] &&
    [ "$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)" = "$SHA256" ]
}
if reusable; then echo "$DEST"; exit 0; fi

# one fetch at a time per cache (parallel builds): a mkdir lock, given up
# after 10 minutes (a stale lock from a killed run: delete $LOCK)
mkdir -p "$CACHE/downloads"
LOCK="$CACHE/.lock-$ARCH"
waited=0
until mkdir "$LOCK" 2>/dev/null; do
  if [ $waited -ge 600 ]; then echo "fetch-cef: $LOCK is held (another fetch, or a stale lock: remove it)" >&2; exit 1; fi
  [ $waited = 0 ] && echo "fetch-cef: waiting for another fetch ($LOCK)" >&2
  sleep 1; waited=$((waited + 1))
done
trap 'rm -rf "$DEST.tmp.$$" "$ARCHIVE.part.$$"; rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
# the other fetch may have finished it while we waited
if reusable; then echo "$DEST"; exit 0; fi

if [ ! -f "$ARCHIVE" ]; then
  URL="https://cef-builds.spotifycdn.com/$(printf %s "$FILE" | sed 's/+/%2B/g')"
  echo "fetch-cef: downloading $FILE" >&2
  curl -sS -f -L --retry 2 -o "$ARCHIVE.part.$$" "$URL"
  mv "$ARCHIVE.part.$$" "$ARCHIVE"
fi
GOT=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
if [ "$GOT" != "$SHA256" ]; then
  echo "fetch-cef: SHA-256 mismatch for $FILE: deleted it (the next run downloads it again)" >&2
  echo "  want $SHA256" >&2
  echo "  got  $GOT" >&2
  rm -f "$ARCHIVE"
  rm -f "$DEST/.ok" # the tree unpacked from it earlier is no longer trusted either
  exit 1
fi
echo "fetch-cef: unpacking into $DEST" >&2
rm -rf "$DEST"
mkdir -p "$DEST.tmp.$$"
tar -xjf "$ARCHIVE" -C "$DEST.tmp.$$" --strip-components 1
touch "$DEST.tmp.$$/.ok"
mv "$DEST.tmp.$$" "$DEST"
echo "$DEST"
