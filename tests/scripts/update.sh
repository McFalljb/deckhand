#!/bin/sh
# Deckhand's own updates (src/update.odin) in test mode, against local files only (file://,
# never GitHub): a fake installed Deckhand.app 0.1.0 in build/update/install (NOT
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
#   4. update-4.txt: keep_sessions on, a pi tab and two counting shells in the session holder;
#      Update to 0.1.3 and Restart to update: nothing asked, the quit hands the terminals over
#      with a successor secret (GOODBYE{handover, successor}), and the relaunch helper
#      (deckhand-core relaunch, --no-open in test mode) waits on successor.sock.
#   4b. update-4b.txt: another copy of Deckhand meanwhile: refused (REFUSED{secret}), no second holder.
#   5. update-5.txt: the "new app" (this test binary as 0.1.3) takes the secret from the helper,
#      is welcomed as the named successor and adopts all three: screen hashes equal to the
#      handover's and to a reference terminal fed every byte, the same pids, counters going on.
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
BIN="$W/deckhand-update-test"
odin build src -out:"$BIN" -define:PI_DESK_UPDATE_TEST=true -minimum-os-version:14.0 &
# the session holder and the relaunch helper (holder_bin_find: next to the app's binary)
odin build src/holder -out:"$W/deckhand-core" -minimum-os-version:14.0 &
wait
[ -x "$BIN" ] && [ -x "$W/deckhand-core" ] || { echo "update scene: the build failed"; exit 1; }
codesign -f -s - -i dev.deckhand.core "$W/deckhand-core" 2>/dev/null
RUN=$(mktemp -d "${TMPDIR:-/tmp}/dkup.XXXXXX") # the holder's socket path must fit in sun_path
holders() { pgrep -f "deckhand-core hold --run $RUN" || true; }
helpers() { pgrep -f "deckhand-core relaunch --pid .* --run $RUN" || true; }
cleanup() {
  cp "$RUN/holder.log" "$W/holder.log" 2>/dev/null || true
  for p in $(holders) $(helpers); do kill -9 "$p" 2>/dev/null || true; done
  rm -rf "$RUN"
}
trap cleanup EXIT
KEY="$W/test.key"
cp tests/update/test-key.txt "$KEY"
chmod 600 "$KEY"
FAKE_HOME="$W/home"
PROJ="$FAKE_HOME/proj"
mkdir -p "$PROJ" "$W/data" "$FAKE_HOME/.pi/agent/sessions/--proj--" "$FAKE_HOME/Chats"
printf '{"type":"session","version":3,"id":"uuuu-1","cwd":"%s"}\n' "$PROJ" \
  > "$FAKE_HOME/.pi/agent/sessions/--proj--/2026-10-30T10-00-00-000Z_uuuu-1.jsonl"

# a fake Deckhand bundle: DIR VERSION [BUNDLE_ID]
mkapp() {
  mkdir -p "$1/Deckhand.app/Contents/MacOS"
  cp /usr/bin/true "$1/Deckhand.app/Contents/MacOS/Deckhand"
  cat > "$1/Deckhand.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${3:-dev.pi-desk.app}</string>
<key>CFBundleExecutable</key><string>Deckhand</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$2</string>
</dict></plist>
PLIST
  codesign --force --sign - "$1/Deckhand.app" 2>/dev/null
}
# a release's assets: VERSION; GOOD=0 signs another zip's manifest (a bad signature)
mkrelease() {
  v=$1 d="$W/rel/download/v$1" z="deckhand-$1-macos-arm64.zip"
  mkdir -p "$d" "$W/src-$v"
  mkapp "$W/src-$v" "$v"
  # UPDATE_RELEASE_SIGN=IDENTITY: the releases signed with that certificate (the install stays ad
  # hoc): an ad-hoc install (0.1.6 and before) updating to a self-signed one (scripts/sign.sh)
  [ -z "${UPDATE_RELEASE_SIGN:-}" ] || codesign --force --sign "$UPDATE_RELEASE_SIGN" "$W/src-$v/Deckhand.app" 2>/dev/null
  (cd "$W/src-$v" && ditto -c -k --keepParent Deckhand.app "$d/$z")
  cd_=$(codesign -d -vvv "$W/src-$v/Deckhand.app" 2>&1 | sed -n 's/^CDHash=//p')
  build/update-sign sign "$KEY" "$v" "$d/$z" "$cd_" "$d/$z.sig" >/dev/null
  if [ "${GOOD:-1}" != 1 ]; then
    # signed, then the zip changes (its checksum follows): only the signature is wrong
    mkdir -p "$W/src-$v/Deckhand.app/Contents/Resources"
    printf 'tampered' > "$W/src-$v/Deckhand.app/Contents/Resources/extra.txt"
    codesign --force --sign - "$W/src-$v/Deckhand.app" 2>/dev/null
    rm "$d/$z"
    (cd "$W/src-$v" && ditto -c -k --keepParent Deckhand.app "$d/$z")
  fi
  (cd "$d" && shasum -a 256 "$z" > "$z.sha256")
  size=$(stat -f%z "$d/$z")
  printf '{"tag_name":"v%s","draft":false,"prerelease":false,"html_url":"https://example.invalid/","assets":[{"name":"%s","size":%s},{"name":"%s.sig","size":%s},{"name":"%s.sha256","size":%s}]}\n' \
    "$v" "$z" "$size" "$z" "$(stat -f%z "$d/$z.sig")" "$z" "$(stat -f%z "$d/$z.sha256")" > "$W/rel/latest.json"
}

mkapp "$W/install" 0.1.0
mkrelease 0.1.1

run() { # SCRIPT VERSION LOG [DIR: what `deckhand DIR` starts in; default the project]
  HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT="$1" PI_DESK_SCRIPT_FAIL_FAST=1 PI_DESK_DATA_DIR="$W/data" PI_DESK_RUNTIME_DIR="$RUN" \
    PI_DESK_UPDATE_URL="file://$W/rel/latest.json" PI_DESK_UPDATE_DOWNLOAD="file://$W/rel/download/" \
    PI_DESK_UPDATE_VERSION="$2" PI_DESK_UPDATE_APP="$W/install/Deckhand.app" \
    PI_DESK_CMD='while [ "${1:-}" = -e ]; do shift 2; done; echo "ARGS: $*"; exec sleep 600' "$BIN" ${4-"$PROJ"} > "$3" 2>&1 || true
}
fail=0
check_log() { # LOG
  grep -E "ASSERT FAILED|done:|TIMEOUT|no element|unknown command" "$1" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$1" || ! grep -q "done:" "$1"; then fail=1; fi
}

run tests/scripts/update.txt 0.1.0 "$W/run1.log"
check_log "$W/run1.log"
v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/install/Deckhand.app/Contents/Info.plist")
[ "$v" = 0.1.1 ] || { echo "the fake install was not swapped to 0.1.1 (it is $v)"; fail=1; }
[ -d "$W/install/Deckhand.app.old-0.1.0" ] || { echo "no backup of the old bundle"; fail=1; }
codesign --verify --deep --strict "$W/install/Deckhand.app" || { echo "the installed bundle does not verify"; fail=1; }
if [ -n "${UPDATE_RELEASE_SIGN:-}" ]; then
  codesign -dr - "$W/install/Deckhand.app" 2>&1 | grep -q 'certificate leaf = H' || { echo "the installed bundle is not the certificate-signed release"; fail=1; }
fi
grep -q "update relaunch: $W/install/Deckhand.app" "$W/run1.log" || { echo "the relaunch was not logged"; fail=1; }
# the relaunched app can start: nothing the old one started (its pi, the relaunch's sh) holds its
# instance lock (src/instance.odin, close-on-exec); run 2 below starts on the same data dir
holders=$(lsof -t "$W/data/instance.lock" 2>/dev/null || true)
[ -z "$holders" ] || { echo "the instance lock is still held after the update quit: $holders"; fail=1; }
ls -a "$W/install" | grep -q '^\.deckhand-update-' && { echo "a staged bundle was left behind"; fail=1; }
[ -d "$W/data/updates" ] && [ -n "$(ls -A "$W/data/updates")" ] && { echo "the download folder was not cleaned up"; fail=1; }
grep -q '"skip":""' "$W/data/update.json" || { echo "update.json: the skip was not cleared by the manual check"; fail=1; }
[ "$(stat -f%Lp "$W/data/update.json")" = 600 ] || { echo "update.json is not 0600"; fail=1; }

GOOD=0 mkrelease 0.1.2
run tests/scripts/update-2.txt 0.1.1 "$W/run2.log"
check_log "$W/run2.log"
grep -q "instance refused" "$W/run2.log" && { echo "the relaunched version was refused by the instance lock"; fail=1; }
[ -d "$W/install/Deckhand.app.old-0.1.0" ] || { echo "the old bundle was removed at the new version's first start"; fail=1; }
v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/install/Deckhand.app/Contents/Info.plist")
[ "$v" = 0.1.1 ] || { echo "a refused update changed the install ($v)"; fail=1; }
ls -a "$W/install" | grep -q '^\.deckhand-update-' && { echo "a refused update left a staged bundle"; fail=1; }
run tests/scripts/update-3.txt 0.1.1 "$W/run3.log"
check_log "$W/run3.log"
[ -e "$W/install/Deckhand.app.old-0.1.0" ] && { echo "the old bundle was not removed at the new version's second start"; fail=1; }

# 4 and 5: an update that keeps the sessions
GOOD=1 mkrelease 0.1.3 # (GOOD=0 above outlives its call in sh)
run tests/scripts/update-4.txt 0.1.1 "$W/run4.log" ""
check_log4() { # like check_log, but the run ends by the update's quit (no "done:")
  grep -E "ASSERT FAILED|TIMEOUT|no element|unknown command|session holder|update relaunch" "$1" || true
  if grep -qE "ASSERT FAILED|TIMEOUT|no element|unknown command" "$1"; then fail=1; fi
}
check_log4 "$W/run4.log"
grep -q "update relaunch: .*(with the successor helper)" "$W/run4.log" || { echo "run 4: no relaunch helper"; fail=1; }
v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$W/install/Deckhand.app/Contents/Info.plist")
[ "$v" = 0.1.3 ] || { echo "run 4: the fake install was not swapped to 0.1.3 (it is $v)"; fail=1; }
[ -n "$(holders)" ] || { echo "run 4: no session holder after the update's quit"; fail=1; }
[ -n "$(helpers)" ] || { echo "run 4: no relaunch helper waiting"; fail=1; }
[ -S "$RUN/successor.sock" ] || { echo "run 4: no successor.sock"; fail=1; }
[ -f "$W/data/handover.json" ] || { echo "run 4: no handover.json"; fail=1; }
# 4b: another copy (another executable, its own data dir) in the minute the holder waits
mkdir -p "$W/other" "$W/data-other"
cp "$BIN" "$W/other/deckhand-update-test"
HOME="$FAKE_HOME" SHELL=/bin/sh PI_DESK_SCRIPT=tests/scripts/update-4b.txt PI_DESK_SCRIPT_FAIL_FAST=1 PI_DESK_DATA_DIR="$W/data-other" PI_DESK_RUNTIME_DIR="$RUN" \
  "$W/other/deckhand-update-test" > "$W/run4b.log" 2>&1 || true
check_log "$W/run4b.log"
grep -q "refused: secret" "$W/run4b.log" || { echo "run 4b: another Deckhand was not refused by the waiting holder"; fail=1; }
[ "$(holders | wc -l | tr -d ' ')" = 1 ] || { echo "run 4b: not exactly one session holder: $(holders)"; fail=1; }
[ -n "$(helpers)" ] || { echo "run 4b: the relaunch helper gave up"; fail=1; }
run tests/scripts/update-5.txt 0.1.3 "$W/run5.log" ""
check_log "$W/run5.log"
grep -q "holder attached: previous handover, 3 terminals, as the named successor" "$W/run5.log" || { echo "run 5: not attached as the named successor"; grep "holder attached" "$W/run5.log"; fail=1; }
python3 - "$W/run4.log" "$W/run5.log" "$ROOT/build/update-before.json" "$ROOT/build/update-after.json" <<'PY' || fail=1
import json, re, sys
log4, log5 = open(sys.argv[1]).read(), open(sys.argv[2]).read()
handed = {m[0]: m[1] for m in re.findall(r"\[autotest\] handover (\d+) offset \d+ hash (\w+)", log4)}
adopted = {m[0]: (m[1], m[2]) for m in re.findall(r"\[autotest\] adopted (\d+) hash (\w+) (exact|inexact)", log5)}
refs = dict(re.findall(r"\[autotest\] adopted_ref (\d+) (\w+)", log5))
fail = []
if len(handed) != 3: fail.append(f"{len(handed)} terminals handed over, want 3 (the pi tab and 2 shells)")
for term, h in handed.items():
    if adopted.get(term) != (h, "exact"): fail.append(f"terminal {term}: handover hash {h}, adopted {adopted.get(term)}")
    if refs.get(term) != "equal": fail.append(f"terminal {term}: against the reference: {refs.get(term)}")
def tabs(p): # the session the scene opened: the one whose tabs are held
    for s in json.load(open(p))["open_sessions"]:
        if any(t.get("held") for t in s["tabs"]): return {t["title"]: t for t in s["tabs"]}
    return {}
before, after = tabs(sys.argv[3]), tabs(sys.argv[4])
if len(before) != 3: fail.append(f"{len(before)} held tabs before the update, want 3")
for title, t in before.items():
    a = after.get(title, {})
    if not t.get("pid") or a.get("pid") != t.get("pid") or a.get("status") != "running" or a.get("inexact"): fail.append(f"{title}: {t.get('pid')} -> {a}")
if fail: sys.exit("run 5: " + "\n".join(fail))
print(f"run 5: {len(handed)} terminals adopted exactly through the update, same pids")
PY
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -z "$(helpers)" ] && break; sleep 0.2; done
[ -z "$(helpers)" ] || { echo "the relaunch helper still runs after the new app took the secret"; fail=1; }
[ -e "$RUN/successor.sock" ] && { echo "successor.sock left behind"; fail=1; }
# the secret (64 hex digits) is in no log
cat "$W/run4.log" "$W/run4b.log" "$W/run5.log" "$RUN/holder.log" 2>/dev/null | grep -qE '[0-9a-f]{64}' && { echo "a 64-hex value (a secret?) in a log"; fail=1; }

# no network: every URL curl got was a local file
grep -q "https://api.github.com" "$W/data/commands.log" 2>/dev/null && { echo "a real URL was used"; fail=1; }

if [ $fail = 1 ]; then echo "update scene failed (logs: $W/run1.log ... $W/run5.log, $W/holder.log)"; exit 1; fi
echo "update scene ok"
