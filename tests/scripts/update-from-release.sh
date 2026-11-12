#!/bin/sh
# Release only (scripts/release.sh runs it after the zip is made; about 1-2 min): the new zip is
# installed by the CURRENT release's updater (docs/plans/background-core.md §7.1, §10.1 PR D).
#
# A published release binary cannot be pointed at a local release (its update fixtures and test
# hooks are compiled out, by design: src/core/test_hooks.odin), so "the current release's updater" is
# its source at its tag, built as that tag's update scene builds it (-define:DECKHAND_UPDATE_TEST=true):
#   1. the latest published release's tag (gh, read only; or --prev TAG), checked out in a
#      temporary worktree, its window, session holder (deckhand-core) and background core
#      (deckhand-core-serve) built side by side, as its Deckhand.app holds them (holder_bin_find,
#      core_serve_bin_find): the window starts that core, and the core runs the update (the window
#      shows it), so the core is the binary built with the test define. 0.2.0 and later only: 0.1.6
#      and older were one process (no src/coremain) and are not supported any more;
#   2. a release JSON and download folder (file://) offering VERSION with the new zip itself, its
#      .sha256, and a .sig over the zip and its bundle's CDHash signed with that tag's THROWAWAY
#      test key (the real .sig is checked by release.sh with build/update-sign verify: the same
#      updatesig code; the test build trusts only the test key);
#   3. that window and its core, in test mode with a fake installed Deckhand of the old version (never
#      /Applications), checks, downloads, checks (sha256, signature, names, links, bundle id,
#      version, codesign, CDHash) and swaps in the new bundle;
#   4. the installed bundle is VERSION, verifies (codesign --deep --strict), has CEF and the
#      session holder, and carries no test hooks (scripts/check-release-build.sh).
# Nothing is uploaded, tagged or published; the worktree is removed at the end.
# Usage: tests/scripts/update-from-release.sh ZIP VERSION [--prev vX.Y.Z]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
[ $# -ge 2 ] || { echo "usage: tests/scripts/update-from-release.sh ZIP VERSION [--prev vX.Y.Z]" >&2; exit 2; }
ZIP=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
VERSION=$2
shift 2
PREV=""
if [ "${1:-}" = --prev ]; then PREV=${2:?--prev needs a tag}; fi
[ -s "$ZIP" ] || { echo "update-from-release: no zip at $ZIP" >&2; exit 1; }
REPO=$(sed -n 's/^UPDATE_REPO :: "\(.*\)"$/\1/p' src/core/update_core.odin)
if [ -z "$PREV" ]; then
  command -v gh >/dev/null || { echo "update-from-release: gh is needed to find the current release (or pass --prev vX.Y.Z)" >&2; exit 1; }
  PREV=$(gh release view --repo "$REPO" --json tagName -q .tagName)
fi
printf %s "$PREV" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+$' || { echo "update-from-release: the current release's tag is '$PREV'" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$PREV^{commit}" >/dev/null || { echo "update-from-release: no tag $PREV here (git fetch --tags)" >&2; exit 1; }
PREV_V=${PREV#v}
[ "$PREV_V" != "$VERSION" ] || { echo "update-from-release: $VERSION is already the current release" >&2; exit 1; }

W="$ROOT/build/update-from-release"
rm -rf "$W"
mkdir -p "$W"
chmod 700 "$W"
PREVDIR="$W/prev"
B="$W/bin"
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkufr.XXXXXX") # the holder's socket path must fit in sun_path
cleanup() {
  # its core, holder or relaunch helper, if one outlived the window (they all run with --run $RUN)
  for p in $(pgrep -f -- "--run $RUN" || true); do kill -9 "$p" 2>/dev/null || true; done
  git worktree remove --force "$PREVDIR" >/dev/null 2>&1 || true
  rm -rf "$RUN"
}
trap cleanup EXIT
echo "update-from-release: $PREV's updater installs $VERSION ($ZIP)"
git worktree add --detach "$PREVDIR" "$PREV" >/dev/null 2>&1
[ -d "$PREVDIR/src/coremain" ] || { echo "update-from-release: $PREV has no separate core (0.1.6 and older): not supported" >&2; exit 1; }
mkdir -p "$B"
# its native libraries (./build.sh fake-app builds them and little else), its window, holder and
# core (as its tests/scripts/update.sh builds them), its signer
(
  cd "$PREVDIR"
  ./build.sh fake-app > "$W/prev-build.log" 2>&1 &&
    odin build src -out:"$B/deckhand" -define:DECKHAND_UPDATE_TEST=true -minimum-os-version:14.0 >> "$W/prev-build.log" 2>&1 &&
    odin build src/holder -out:"$B/deckhand-core" -minimum-os-version:14.0 >> "$W/prev-build.log" 2>&1 &&
    # the core's Obj-C shim (its build.sh's build_core makes it; fake-app does not)
    clang -c -O2 -Wall -fobjc-arc -mmacosx-version-min=14.0 src/coremain/core_macos.m -o build/dh_coremain.o >> "$W/prev-build.log" 2>&1 &&
    ar rcs build/dh_coremain.a build/dh_coremain.o &&
    odin build src/coremain -out:"$B/deckhand-core-serve" -define:DECKHAND_UPDATE_TEST=true -minimum-os-version:14.0 >> "$W/prev-build.log" 2>&1 &&
    odin build tools/update-sign -out:"$W/update-sign" >> "$W/prev-build.log" 2>&1
) || { tail -20 "$W/prev-build.log"; echo "update-from-release: $PREV did not build (log: $W/prev-build.log)" >&2; exit 1; }
# the identifiers the window and the core check in each other (trust.WINDOW_IDS, the core's)
codesign -f -s - -i dev.deckhand.core "$B/deckhand-core" 2>/dev/null
codesign -f -s - -i dev.deckhand.core "$B/deckhand-core-serve" 2>/dev/null
codesign -f -s - -i dev.pi-desk.app "$B/deckhand" 2>/dev/null
mkdir -p "$W/keys"
chmod 700 "$W/keys"
cp "$PREVDIR/tests/update/test-key.txt" "$W/keys/test.key"
chmod 600 "$W/keys/test.key"

# the release, as the old updater would find it on GitHub
NAME=$(basename "$ZIP")
D="$W/rel/download/v$VERSION"
mkdir -p "$D" "$W/x"
cp "$ZIP" "$D/$NAME"
ditto -x -k "$D/$NAME" "$W/x" # the copy: the one signed and offered
CDHASH=$(codesign -d -vvv "$W/x/Deckhand.app" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
[ -n "$CDHASH" ] || { echo "update-from-release: the zip's Deckhand.app has no CDHash" >&2; exit 1; }
rm -rf "$W/x"
"$W/update-sign" sign "$W/keys/test.key" "$VERSION" "$D/$NAME" "$CDHASH" "$D/$NAME.sig" >/dev/null
(cd "$D" && shasum -a 256 "$NAME" > "$NAME.sha256")
printf '{"tag_name":"v%s","draft":false,"prerelease":false,"html_url":"https://example.invalid/","assets":[{"name":"%s","size":%s},{"name":"%s.sig","size":%s},{"name":"%s.sha256","size":%s}]}\n' \
  "$VERSION" "$NAME" "$(stat -f%z "$D/$NAME")" "$NAME" "$(stat -f%z "$D/$NAME.sig")" "$NAME" "$(stat -f%z "$D/$NAME.sha256")" > "$W/rel/latest.json"

# a fake installed Deckhand of the old version (the old updater replaces only this)
I="$W/install/Deckhand.app"
mkdir -p "$I/Contents/MacOS"
cp /usr/bin/true "$I/Contents/MacOS/Deckhand"
cat > "$I/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.pi-desk.app</string>
<key>CFBundleExecutable</key><string>Deckhand</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$PREV_V</string>
<key>CFBundleVersion</key><string>$PREV_V</string>
</dict></plist>
PLIST
codesign --force --sign - "$I" 2>/dev/null

cat > "$W/script.txt" <<SCRIPT
# the current release's window and core ($PREV) install $VERSION (tests/scripts/update-from-release.sh)
wait 1500
waitstate 10000 update.available true
assert_state update.latest $VERSION
clickid update_go
waitstate 240000 update.phase ready
ui_command {"type":"update_install"}
waitstate 10000 update.phase installed
quit
SCRIPT
mkdir -p "$W/home" "$W/data"
HOME="$W/home" SHELL=/bin/sh DECKHAND_SCRIPT="$W/script.txt" DECKHAND_DATA_DIR="$W/data" DECKHAND_RUNTIME_DIR="$RUN" \
  DECKHAND_UPDATE_URL="file://$W/rel/latest.json" DECKHAND_UPDATE_DOWNLOAD="file://$W/rel/download/" \
  DECKHAND_UPDATE_VERSION="$PREV_V" DECKHAND_UPDATE_APP="$I" \
  "$B/deckhand" > "$W/run.log" 2>&1 || true
# the core's own log (the download, the checks, the swap), without its control token
if [ -f "$RUN/core.log" ]; then grep -v '^export DECKHAND_SOCKET=' "$RUN/core.log" > "$W/core.log" || true; fi

fail=0
grep -E "ASSERT FAILED|TIMEOUT|done:" "$W/run.log" || true
if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$W/run.log" || ! grep -q "done:" "$W/run.log"; then fail=1; fi
v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$I/Contents/Info.plist" 2>/dev/null || true)
[ "$v" = "$VERSION" ] || { echo "update-from-release: the install is $v, not $VERSION"; fail=1; }
codesign --verify --deep --strict "$I" || { echo "update-from-release: the installed bundle does not verify"; fail=1; }
[ -d "$I/Contents/Frameworks/Chromium Embedded Framework.framework" ] || { echo "update-from-release: no CEF in the installed bundle"; fail=1; }
CORE="$I/Contents/Helpers/Deckhand Core.app"
[ -x "$CORE/Contents/MacOS/deckhand-core" ] || { echo "update-from-release: no session holder (Deckhand Core.app) in the installed bundle"; fail=1; }
scripts/check-release-build.sh "$I/Contents/MacOS/Deckhand" "$CORE/Contents/MacOS/deckhand-core" "$CORE/Contents/MacOS/deckhand" || fail=1
if [ $fail = 1 ]; then echo "update-from-release: FAILED (logs: $W/run.log, $W/core.log)"; exit 1; fi
rm -rf "$W/install" "$W/rel"
echo "update-from-release: $PREV's updater installed $VERSION"
