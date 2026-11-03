#!/bin/sh
# pi-desk's own updates (src/update.odin) in test mode, against local files only (file://,
# never GitHub): a fake installed pi-desk.app 0.1.0 in build/update/install (NOT
# /Applications), a "latest release" JSON and its assets made here: ad-hoc-signed fake
# bundles, zipped with ditto, their .sha256, and .sig files signed with the THROWAWAY test
# key (tests/update/test-key.txt) by build/update-sign. Two runs, same data dir:
#   1. update.txt: the bar appears, Skip hides it, Check for Updates offers it again,
#      Update downloads and checks 0.1.1, Restart to update asks (a pi tab runs), the
#      swap happens in the fake install dir and the relaunch is only logged.
#   2. update-2.txt: the next start keeps the old bundle (the new version's first start);
#      0.1.2's signature does not match its zip: refused with a clear message, nothing
#      installed.
#   3. update-3.txt: the new version's second start removes the old bundle.
# The app runs as its own test build (-define:PI_DESK_UPDATE_TEST=true, without the browser):
# a release build has neither the test key nor the fixture variables compiled in.
# Usage: tests/scripts/update.sh   (needs ./build.sh's libraries; builds build/update-sign)
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
W="$ROOT/build/update"
rm -rf "$W" build/shots/update
mkdir -p "$W" build/shots/update
odin build tools/update-sign -out:build/update-sign
BIN="$W/pi-desk-update-test"
odin build src -out:"$BIN" -define:PI_DESK_UPDATE_TEST=true -minimum-os-version:14.0
KEY="$W/test.key"
cp tests/update/test-key.txt "$KEY"
chmod 600 "$KEY"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--" "$FAKE_HOME/Chats"
printf '{"type":"session","version":3,"id":"uuuu-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_uuuu-1.jsonl"

# a fake pi-desk bundle: DIR VERSION [BUNDLE_ID]
mkapp() {
  mkdir -p "$1/pi-desk.app/Contents/MacOS"
  cp /usr/bin/true "$1/pi-desk.app/Contents/MacOS/pi-desk"
  cat > "$1/pi-desk.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${3:-dev.pi-desk.app}</string>
<key>CFBundleExecutable</key><string>pi-desk</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$2</string>
</dict></plist>
PLIST
  codesign --force --sign - "$1/pi-desk.app" 2>/dev/null
}
# a release's assets: VERSION; GOOD=0 signs another zip's manifest (a bad signature)
mkrelease() {
  v=$1 d="$W/rel/download/v$1" z="pi-desk-$1-macos-arm64.zip"
  mkdir -p "$d" "$W/src-$v"
  mkapp "$W/src-$v" "$v"
  (cd "$W/src-$v" && ditto -c -k --keepParent pi-desk.app "$d/$z")
  cd_=$(codesign -d -vvv "$W/src-$v/pi-desk.app" 2>&1 | sed -n 's/^CDHash=//p')
  build/update-sign sign "$KEY" "$v" "$d/$z" "$cd_" "$d/$z.sig" >/dev/null
  if [ "${GOOD:-1}" != 1 ]; then
    # signed, then the zip changes (its checksum follows): only the signature is wrong
    mkdir -p "$W/src-$v/pi-desk.app/Contents/Resources"
    printf 'tampered' > "$W/src-$v/pi-desk.app/Contents/Resources/extra.txt"
    codesign --force --sign - "$W/src-$v/pi-desk.app" 2>/dev/null
    rm "$d/$z"
    (cd "$W/src-$v" && ditto -c -k --keepParent pi-desk.app "$d/$z")
  fi
  (cd "$d" && shasum -a 256 "$z" > "$z.sha256")
  size=$(stat -f%z "$d/$z")
  printf '{"tag_name":"v%s","draft":false,"prerelease":false,"html_url":"https://example.invalid/","assets":[{"name":"%s","size":%s},{"name":"%s.sig","size":%s},{"name":"%s.sha256","size":%s}]}\n' \
    "$v" "$z" "$size" "$z" "$(stat -f%z "$d/$z.sig")" "$z" "$(stat -f%z "$d/$z.sha256")" > "$W/rel/latest.json"
}

mkapp "$W/install" 0.1.0
mkrelease 0.1.1

run() { # SCRIPT
  HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$1" PI_DESK_DATA_DIR="$W/data" \
    PI_DESK_UPDATE_URL="file://$W/rel/latest.json" PI_DESK_UPDATE_DOWNLOAD="file://$W/rel/download/" \
    PI_DESK_UPDATE_VERSION="$2" PI_DESK_UPDATE_APP="$W/install/pi-desk.app" \
    PI_DESK_CMD='echo "ARGS: $*"; exec sleep 600' "$BIN" "$PROJ" > "$3" 2>&1 || true
}
fail=0
check_log() { # LOG
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$1" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$1" || ! grep -q "done:" "$1"; then fail=1; fi
}

run tests/scripts/update.txt 0.1.0 "$W/run1.log"
check_log "$W/run1.log"
v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/install/pi-desk.app/Contents/Info.plist")
[ "$v" = 0.1.1 ] || { echo "the fake install was not swapped to 0.1.1 (it is $v)"; fail=1; }
[ -d "$W/install/pi-desk.app.old-0.1.0" ] || { echo "no backup of the old bundle"; fail=1; }
codesign --verify --deep --strict "$W/install/pi-desk.app" || { echo "the installed bundle does not verify"; fail=1; }
grep -q "update relaunch: $W/install/pi-desk.app" "$W/run1.log" || { echo "the relaunch was not logged"; fail=1; }
ls -a "$W/install" | grep -q '^\.pi-desk-update-' && { echo "a staged bundle was left behind"; fail=1; }
[ -d "$W/data/updates" ] && [ -n "$(ls -A "$W/data/updates")" ] && { echo "the download folder was not cleaned up"; fail=1; }
grep -q '"skip":""' "$W/data/update.json" || { echo "update.json: the skip was not cleared by the manual check"; fail=1; }
[ "$(stat -f%Lp "$W/data/update.json")" = 600 ] || { echo "update.json is not 0600"; fail=1; }

GOOD=0 mkrelease 0.1.2
run tests/scripts/update-2.txt 0.1.1 "$W/run2.log"
check_log "$W/run2.log"
[ -d "$W/install/pi-desk.app.old-0.1.0" ] || { echo "the old bundle was removed at the new version's first start"; fail=1; }
v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/install/pi-desk.app/Contents/Info.plist")
[ "$v" = 0.1.1 ] || { echo "a refused update changed the install ($v)"; fail=1; }
ls -a "$W/install" | grep -q '^\.pi-desk-update-' && { echo "a refused update left a staged bundle"; fail=1; }
run tests/scripts/update-3.txt 0.1.1 "$W/run3.log"
check_log "$W/run3.log"
[ -e "$W/install/pi-desk.app.old-0.1.0" ] && { echo "the old bundle was not removed at the new version's second start"; fail=1; }
# no network: every URL curl got was a local file
grep -q "https://api.github.com" "$W/data/commands.log" 2>/dev/null && { echo "a real URL was used"; fail=1; }

if [ $fail = 1 ]; then echo "update scene failed (logs: $W/run1.log $W/run2.log $W/run3.log)"; exit 1; fi
echo "update scene ok"
