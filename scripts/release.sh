#!/bin/sh
# Make a Deckhand release, on the release signer's Mac, in one command (docs/DEVELOPING.md,
# "Releases"): checks, build (with CEF) and tests, the version in Info.plist, code signing
# (optional Developer ID and notarization), the zip and its SHA-256, the updater's signature
# (.sig) from the bundle just built, then a DRAFT GitHub Release with the three files, whose
# .sig is downloaded again and verified against the local zip. Publish the draft on GitHub.
#
# Usage: scripts/release.sh --version X.Y.Z [--no-upload | --upload-only] [--key FILE]
#                           [--repo OWNER/NAME [--allow-other-repo]] [--rotating-from OLDPUB]
#   --version      the version; HEAD must be exactly the tag vX.Y.Z (git describe
#                  --exact-match), already pushed to the release repository
#   --no-upload    a dry run: everything into dist/, no GitHub calls at all
#   --upload-only  draft what an earlier --no-upload run left in dist/ (checked again first)
#   --key FILE     the update key (default: $PI_DESK_UPDATE_KEY_FILE, else
#                  ~/.config/pi-desk/update.key); a 600 file of yours in a private folder,
#                  read only by build/update-sign
#   --repo         the GitHub repository (default: $PI_DESK_RELEASE_REPO, else UPDATE_REPO in
#                  src/update_core.odin, the repository the app's updater reads)
#   --allow-other-repo
#                  release to a repository that is not UPDATE_REPO (a fork, a test): installed
#                  copies never look there
#   --rotating-from OLDPUB
#                  the key-rotation bridge release only: this checkout's UPDATE_PUBLIC_KEY is the
#                  NEW key, and the release is signed with the OLD key (--key OLDFILE, whose
#                  public half must be OLDPUB), the one installed copies trust
#
# Refuses, before building anything, unless: X.Y.Z (no pre-releases: the updater never offers
# them); the worktree is clean (no changes, no untracked files); HEAD is exactly the tag vX.Y.Z;
# src/update_key.odin has a real key; the key file's public half is that key. After the build:
# the app's main executable holds UPDATE_PUBLIC_KEY and not the test key.
#
# Code signing, from the environment (never printed): MACOS_CERT_P12 (base64 of a .p12 with a
#   "Developer ID Application" identity) and MACOS_CERT_PASSWORD: Developer ID signature,
#   hardened runtime, the entitlements in scripts/entitlements/. Plus APPLE_ID, APPLE_TEAM_ID
#   and APPLE_APP_PASSWORD (an app-specific password): notarized and stapled. Without them:
#   signed ad hoc (as build.sh already does), not notarized; the notes say how to open it.
#
# Writes dist/deckhand-<version>-macos-arm64.zip (holding Deckhand.app), its .sha256, its .sig and
# release-notes.md.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VERSION="" UPLOAD=1 PACKAGE=1 ROTATING_FROM="" ALLOW_OTHER_REPO=0
KEY=${PI_DESK_UPDATE_KEY_FILE:-$HOME/.config/pi-desk/update.key}
# the repository: the one the app's updater reads (src/update_core.odin's UPDATE_REPO)
APP_REPO=$(sed -n 's/^UPDATE_REPO :: "\(.*\)"$/\1/p' src/update_core.odin)
[ -n "$APP_REPO" ] || { echo "release: no UPDATE_REPO in src/update_core.odin" >&2; exit 1; }
REPO=${PI_DESK_RELEASE_REPO:-$APP_REPO}
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=${2:?--version needs a value}; shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    --upload-only) PACKAGE=0; shift ;;
    --key) KEY=${2:?--key needs a file}; shift 2 ;;
    --repo) REPO=${2:?--repo needs OWNER/NAME}; shift 2 ;;
    --rotating-from) ROTATING_FROM=${2:?--rotating-from needs the old public key}; shift 2 ;;
    --allow-other-repo) ALLOW_OTHER_REPO=1; shift ;;
    -h|--help) sed -n '2,/^set -eu/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "release: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ "$REPO" != "$APP_REPO" ] && [ $ALLOW_OTHER_REPO = 0 ]; then
  echo "release: $REPO (from --repo or PI_DESK_RELEASE_REPO) is not the repository the app updates from ($APP_REPO, UPDATE_REPO in src/update_core.odin): installed copies would never see this release. Pass --allow-other-repo if that is what you want" >&2
  exit 1
fi
if [ $PACKAGE = 0 ] && [ $UPLOAD = 0 ]; then
  echo "release: --upload-only and --no-upload leave nothing to do" >&2; exit 2
fi
if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
  echo "release: macOS arm64 only (the browser tab's CEF is wired up for arm64)" >&2; exit 1
fi

# --- what is released: a clean tree at exactly the tag ----------------------------------------
VERSION=${VERSION#v}
case "$VERSION" in *-*|*+*) echo "release: $VERSION is a pre-release: Deckhand releases X.Y.Z only (the updater never offers pre-releases)" >&2; exit 1 ;; esac
if ! printf %s "$VERSION" | grep -Eq '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$'; then
  echo "release: --version X.Y.Z is needed (got '$VERSION')" >&2
  exit 1
fi
TAG="v$VERSION"
PLIST_VERSION=$VERSION
if [ -n "$(git status --porcelain --untracked-files=normal)" ]; then
  echo "release: the worktree is not clean (commit or remove every change and untracked file first)" >&2
  exit 1
fi
AT=$(git describe --tags --exact-match --match "$TAG" HEAD 2>/dev/null || true)
[ "$AT" = "$TAG" ] || { echo "release: HEAD is not exactly the tag $TAG (git tag $TAG at the commit to release, push it, check it out)" >&2; exit 1; }

# --- the update key: real, and the one this checkout's app trusts ----------------------------
APP_PUB=$(sed -n 's/^UPDATE_PUBLIC_KEY :: "\(.*\)"$/\1/p' src/update_key.odin)
case "$APP_PUB" in
  ""|PLACEHOLDER*) echo "release: src/update_key.odin still has the placeholder update key: put the real public key in first (docs/DEVELOPING.md, \"Update signing\")" >&2; exit 1 ;;
esac
mkdir -p build
[ -x build/update-sign ] && [ ! tools/update-sign/main.odin -nt build/update-sign ] && [ ! src/updatesig/updatesig.odin -nt build/update-sign ] ||
  odin build tools/update-sign -out:build/update-sign
KEY_PUB=$(build/update-sign pubkey "$KEY") || { echo "release: the update key file is not usable: $KEY" >&2; exit 1; }
# SIGN_PUB: the public key the .sig must verify under (the one installed copies trust)
if [ -z "$ROTATING_FROM" ]; then
  [ "$KEY_PUB" = "$APP_PUB" ] ||
    { echo "release: the key file's public half is not src/update_key.odin's UPDATE_PUBLIC_KEY (wrong key, or a checkout from before a key rotation)" >&2; exit 1; }
  SIGN_PUB=$APP_PUB
else
  [ "$ROTATING_FROM" != "$APP_PUB" ] ||
    { echo "release: --rotating-from is the old key, and src/update_key.odin already has the new one: they are the same here" >&2; exit 1; }
  [ "$KEY_PUB" = "$ROTATING_FROM" ] ||
    { echo "release: --rotating-from: the key file's public half is not OLDPUB (sign the bridge release with the old key)" >&2; exit 1; }
  echo "release: key rotation bridge release: signed with the old key, the app trusts the new one"
  SIGN_PUB=$ROTATING_FROM
fi

DIST=dist
# the app, and the release files the updater looks for: read from its source, never typed here
# (src/update_core.odin UPDATE_APP; src/updatesig/updatesig.odin ZIP_PREFIX and ZIP_SUFFIX)
APP_NAME=$(sed -n 's/^UPDATE_APP :: "\(.*\)"$/\1/p' src/update_core.odin)
ZIP_PREFIX=$(sed -n 's/^ZIP_PREFIX :: "\(.*\)"$/\1/p' src/updatesig/updatesig.odin)
ZIP_SUFFIX=$(sed -n 's/^ZIP_SUFFIX :: "\(.*\)"$/\1/p' src/updatesig/updatesig.odin)
case "$APP_NAME" in */*|"") echo "release: no usable UPDATE_APP in src/update_core.odin" >&2; exit 1 ;; *.app) ;; *) echo "release: UPDATE_APP in src/update_core.odin is not an .app" >&2; exit 1 ;; esac
case "$ZIP_PREFIX" in */*|"") echo "release: no usable ZIP_PREFIX in src/updatesig/updatesig.odin" >&2; exit 1 ;; esac
case "$ZIP_SUFFIX" in */*|"") echo "release: no usable ZIP_SUFFIX in src/updatesig/updatesig.odin" >&2; exit 1 ;; *.zip) ;; *) echo "release: ZIP_SUFFIX in src/updatesig/updatesig.odin does not end in .zip" >&2; exit 1 ;; esac
NAME="$ZIP_PREFIX$VERSION${ZIP_SUFFIX%.zip}"
NOTES="$DIST/release-notes.md"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/deckhand-release.XXXXXX")
KC=""
OLD_KEYCHAINS=""
cleanup() {
  if [ -n "$KC" ]; then
    # shellcheck disable=SC2086 # the saved search list, one path per word
    [ -n "$OLD_KEYCHAINS" ] && security list-keychains -d user -s $OLD_KEYCHAINS >/dev/null 2>&1 || true
    security delete-keychain "$KC" >/dev/null 2>&1 || true
    KC=""
  fi
  [ -z "$TMP" ] || rm -rf "$TMP"
  TMP=""
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

if [ $PACKAGE = 1 ]; then
# --- build and test ------------------------------------------------------------------
./build.sh test
# the time budgets at their own limits (the perf layer: docs/TESTING.md "Timing tests"): a summary
# to read, never a reason to stop (./build.sh test above gates on 10x and 3x)
python3 tests/unit.py --no-build --timing-only --perf-strict >build/release-perf.log 2>&1 ||
  { grep -E "PERF OVER|^unit: perf" build/release-perf.log | sed 's/^/release: warning: /'; echo "release: warning: time budgets over their limits on this machine (build/release-perf.log); not stopping" >&2; }
./build.sh # release build with CEF; bundle-app.sh lays out and ad-hoc signs build/Deckhand.app
BUILT=build/$APP_NAME
EXE_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$BUILT/Contents/Info.plist" 2>/dev/null || true)
EXE=$BUILT/Contents/MacOS/$EXE_NAME
[ -n "$EXE_NAME" ] && [ -x "$EXE" ] || { echo "release: no $BUILT with its executable (run ./build.sh; UPDATE_APP must be what build.sh makes)" >&2; exit 1; }
# the app must trust the release key, and never the test key (a test build would trust the
# public test key: -define:PI_DESK_UPDATE_TEST)
LC_ALL=C grep -aqF "$APP_PUB" "$EXE" ||
  { echo "release: $BUILT does not contain UPDATE_PUBLIC_KEY" >&2; exit 1; }
TEST_PUB=$(sed -n 's/^.*UPDATE_TEST_PUBLIC_KEY :: "\(.*\)"$/\1/p' src/update_key.odin)
if [ -n "$TEST_PUB" ] && LC_ALL=C grep -aqF "$TEST_PUB" "$EXE"; then
  echo "release: $BUILT has the update TEST key in it (a test build?)" >&2
  exit 1
fi
[ -d "$BUILT/Contents/Frameworks/Chromium Embedded Framework.framework" ] ||
  { echo "release: $BUILT has no CEF framework (a PI_DESK_NO_CEF build?)" >&2; exit 1; }

STAGE="$DIST/stage"
APP="$STAGE/$APP_NAME"
FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
rm -rf "$STAGE" "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256" "$DIST/$NAME.zip.sig" "$NOTES"
mkdir -p "$STAGE"
ditto "$BUILT" "$APP"

# --- version into every Info.plist ---------------------------------------------------
PB=/usr/libexec/PlistBuddy
for p in "$APP/Contents/Info.plist" "$APP"/Contents/Frameworks/*Helper*.app/Contents/Info.plist; do
  $PB -c "Set :CFBundleShortVersionString $PLIST_VERSION" "$p"
  $PB -c "Set :CFBundleVersion $PLIST_VERSION" "$p"
done

for f in LICENSE THIRD_PARTY_NOTICES.md CEF-LICENSE.txt CHROMIUM-CREDITS.html; do
  [ -s "$APP/Contents/Resources/licenses/$f" ] || { echo "release: licenses/$f missing from the app" >&2; exit 1; }
done

# --- signing -------------------------------------------------------------------------
SIGNED=adhoc
NOTARIZED=0

if [ -n "${MACOS_CERT_P12:-}" ] && [ -n "${MACOS_CERT_PASSWORD:-}" ]; then
  echo "release: signing with a Developer ID (hardened runtime)"
  # a throwaway keychain, so neither CI nor a local run touches the login keychain's identities
  KC="$TMP/signing.keychain-db"
  KC_PASS=$(openssl rand -hex 24)
  security create-keychain -p "$KC_PASS" "$KC"
  security set-keychain-settings -lut 7200 "$KC"
  security unlock-keychain -p "$KC_PASS" "$KC"
  printf %s "$MACOS_CERT_P12" | base64 --decode > "$TMP/cert.p12"
  security import "$TMP/cert.p12" -k "$KC" -P "$MACOS_CERT_PASSWORD" -T /usr/bin/codesign >/dev/null
  rm -f "$TMP/cert.p12"
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KC" >/dev/null
  OLD_KEYCHAINS=$(security list-keychains -d user | tr -d '"')
  # shellcheck disable=SC2086
  security list-keychains -d user -s "$KC" $OLD_KEYCHAINS
  IDENTITY=$(security find-identity -v -p codesigning "$KC" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
  [ -n "$IDENTITY" ] || { echo "release: MACOS_CERT_P12 has no 'Developer ID Application' identity" >&2; exit 1; }
  sign() { codesign --force --timestamp --options runtime --keychain "$KC" --sign "$IDENTITY" "$@"; }
  # inside out: the framework's libraries, the framework, the helpers, the app (no --deep)
  for lib in "$FW/Libraries/"*.dylib; do sign "$lib"; done
  sign "$FW"
  for h in "$APP"/Contents/Frameworks/*Helper*.app; do
    case "$h" in
      *"Helper (Plugin).app") sign --entitlements scripts/entitlements/helper-plugin.plist "$h" ;;
      *) sign --entitlements scripts/entitlements/helper.plist "$h" ;;
    esac
  done
  sign "$APP/Contents/MacOS/pi-desk-cli" # Claude tabs' CLI (src/claude.odin)
  # the session holder (src/holder): holder_install checks this identifier on its copy
  if [ -f "$APP/Contents/Helpers/deckhand-core" ]; then sign --identifier dev.deckhand.core "$APP/Contents/Helpers/deckhand-core"; fi
  sign --entitlements scripts/entitlements/app.plist "$APP"
  SIGNED=developer-id
else
  echo "release: no MACOS_CERT_P12: signing ad hoc"
  # bundle-app.sh signed the framework, the helpers and the app ad hoc; the version edits
  # above changed the helpers' and the app's Info.plist, so those two levels are signed again
  # (inside out, no --deep; the framework is untouched and keeps its signature)
  for h in "$APP"/Contents/Frameworks/*Helper*.app; do codesign --force --sign - "$h"; done
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

if [ $SIGNED = developer-id ] && [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APPLE_APP_PASSWORD:-}" ]; then
  echo "release: notarizing (this waits for Apple)"
  ditto -c -k --keepParent "$APP" "$TMP/notarize.zip"
  # --wait returns when Apple decides; the verdict is read from the JSON, not the exit code
  xcrun notarytool submit "$TMP/notarize.zip" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_PASSWORD" --wait --timeout 30m --output-format json > "$TMP/notary.json" || true
  SUB_ID=$(plutil -extract id raw -o - "$TMP/notary.json" 2>/dev/null || true)
  SUB_STATUS=$(plutil -extract status raw -o - "$TMP/notary.json" 2>/dev/null || true)
  echo "release: notarization ${SUB_ID:-(no submission id)}: ${SUB_STATUS:-(no status)}"
  if [ "$SUB_STATUS" != Accepted ]; then
    if [ -n "$SUB_ID" ]; then
      xcrun notarytool log "$SUB_ID" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" >&2 || true
    else
      cat "$TMP/notary.json" >&2 || true
    fi
    echo "release: notarization not accepted" >&2
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  NOTARIZED=1
elif [ $SIGNED = developer-id ]; then
  echo "release: APPLE_ID, APPLE_TEAM_ID or APPLE_APP_PASSWORD missing: signed, not notarized" >&2
fi

# --- zip and checksum ----------------------------------------------------------------
ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"
(cd "$DIST" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")


# --- release notes -------------------------------------------------------------------
{
  echo "Deckhand $VERSION for macOS 14 or later on Apple silicon (arm64)."
  echo
  echo "Deckhand checks for new releases about once a day and asks before it updates itself;"
  echo "\`$NAME.zip.sig\` is the signature it checks. To install by hand, download"
  echo "\`$NAME.zip\` and check it against \`$NAME.zip.sha256\`:"
  echo
  echo '```sh'
  echo "shasum -a 256 -c $NAME.zip.sha256"
  echo '```'
  echo
  if [ $NOTARIZED = 1 ]; then
    echo "The app is signed with a Developer ID and notarized by Apple."
  else
    echo "**This app is not signed with an Apple Developer ID or notarized** (it is signed ad hoc),"
    echo "so macOS refuses to open it the first time. After unzipping and moving \`$APP_NAME\` to"
    echo "Applications, either right-click it and choose **Open** (macOS 14), or open it once and then"
    echo "click **Open Anyway** in System Settings › Privacy & Security (macOS 15 and later), or clear"
    echo "the quarantine flag:"
    echo
    echo '```sh'
    echo "xattr -dr com.apple.quarantine /Applications/$APP_NAME"
    echo '```'
  fi
  echo
  echo "Deckhand runs your own [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent);"
  echo "[pi-kit](https://github.com/McFalljb/pi-kit) is optional. Third-party licences are in"
  echo "\`$APP_NAME/Contents/Resources/licenses/\`."
} > "$NOTES"

# --- the update signature: from the bundle just built, never from anything downloaded -----
# what the zip holds is what was zipped: unpack it, check it, take the CDHash from it
mkdir "$TMP/check"
ditto -x -k "$DIST/$NAME.zip" "$TMP/check"
[ "$(ls -A "$TMP/check")" = "$APP_NAME" ] || { echo "release: the zip does not hold exactly $APP_NAME" >&2; exit 1; }
codesign --verify --deep --strict "$TMP/check/$APP_NAME"
CDHASH=$(codesign -d -vvv "$APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
CHECK_CDHASH=$(codesign -d -vvv "$TMP/check/$APP_NAME" 2>&1 | sed -n 's/^CDHash=//p' | head -1)
[ -n "$CDHASH" ] && [ "$CDHASH" = "$CHECK_CDHASH" ] ||
  { echo "release: the zipped app's CDHash ($CHECK_CDHASH) is not the built one's ($CDHASH)" >&2; exit 1; }
build/update-sign sign "$KEY" "$VERSION" "$DIST/$NAME.zip" "$CDHASH" "$DIST/$NAME.zip.sig"
build/update-sign verify "$SIGN_PUB" "$VERSION" "$DIST/$NAME.zip" "$DIST/$NAME.zip.sig"

echo "release: $DIST/$NAME.zip ($(du -h "$DIST/$NAME.zip" | cut -f1)), signature: $SIGNED, notarized: $NOTARIZED, update CDHash: $CDHASH"
cat "$DIST/$NAME.zip.sha256"
cleanup
fi # PACKAGE

# --- the draft GitHub Release --------------------------------------------------------------
if [ $UPLOAD = 0 ]; then
  echo "release: --no-upload: stopping before GitHub (scripts/release.sh --version $VERSION --upload-only drafts it)"
  exit 0
fi
[ -n "$TMP" ] || TMP=$(mktemp -d "${TMPDIR:-/tmp}/deckhand-release.XXXXXX")
for f in "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256" "$DIST/$NAME.zip.sig" "$NOTES"; do
  [ -s "$f" ] || { echo "release: $f missing (run without --upload-only first)" >&2; exit 1; }
done
# what goes up is what was signed here
(cd "$DIST" && shasum -a 256 -c "$NAME.zip.sha256") >/dev/null ||
  { echo "release: $DIST/$NAME.zip does not match its .sha256" >&2; exit 1; }
build/update-sign verify "$SIGN_PUB" "$VERSION" "$DIST/$NAME.zip" "$DIST/$NAME.zip.sig" >/dev/null ||
  { echo "release: $DIST/$NAME.zip.sig does not verify" >&2; exit 1; }
command -v gh >/dev/null || { echo "release: gh (GitHub CLI) is needed to upload" >&2; exit 1; }
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  # a re-run: replace the assets, but only on a release nobody has published yet
  IS_DRAFT=$(gh release view "$TAG" --repo "$REPO" --json isDraft -q .isDraft)
  if [ "$IS_DRAFT" != true ]; then
    echo "release: $TAG is already published: refusing to replace its assets" >&2
    exit 1
  fi
  gh release upload "$TAG" --repo "$REPO" --clobber "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256" "$DIST/$NAME.zip.sig"
else
  # --verify-tag: the tag must already be on GitHub (gh would otherwise make one)
  gh release create "$TAG" --repo "$REPO" --draft --verify-tag --title "Deckhand $VERSION" \
    --notes-file "$NOTES" --generate-notes "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256" "$DIST/$NAME.zip.sig"
fi
# the round trip: what GitHub serves is what was signed here
mkdir -p "$TMP/rt"
gh release download "$TAG" --repo "$REPO" -p "$NAME.zip.sig" -D "$TMP/rt"
cmp -s "$DIST/$NAME.zip.sig" "$TMP/rt/$NAME.zip.sig" || { echo "release: the uploaded .sig differs from the one signed" >&2; exit 1; }
build/update-sign verify "$SIGN_PUB" "$VERSION" "$DIST/$NAME.zip" "$TMP/rt/$NAME.zip.sig"
echo "release: draft $TAG on $REPO has the zip, .sha256 and .sig; check it and publish it on GitHub"
