#!/bin/sh
# Package a pi-desk release: build (with CEF), tests, the version in Info.plist, signing,
# a zip and its SHA-256, and a DRAFT GitHub Release. .github/workflows/release.yml runs this
# in three steps so the secrets and the write token never meet the build:
#   1. ./build.sh test && ./build.sh                      (no secrets)
#   2. scripts/release.sh --tag T --skip-build --no-upload  (signing/notarization secrets only)
#   3. scripts/release.sh --tag T --upload-only             (GH_TOKEN only)
# A local run is the same path in one go: scripts/release.sh --version X.Y.Z --no-upload.
#
# Usage: scripts/release.sh [--version X.Y.Z] [--tag vX.Y.Z] [--no-upload] [--skip-build]
#                           [--upload-only]
#   --version     the version (default: from --tag, $GITHUB_REF_NAME when it is a v* tag, or
#                 the v* tag on HEAD). A leading "v" is dropped.
#   --tag         the git tag the release is drafted for (default: v<version>); it must exist
#   --no-upload   stop after dist/ (no GitHub calls at all)
#   --skip-build  package the build/pi-desk.app already there (no build, no tests)
#   --upload-only upload what an earlier run left in dist/ (no build, no signing)
#
# Signing, from the environment (repository secrets in CI; none of them is ever printed):
#   MACOS_CERT_P12 (base64 of a .p12 with a "Developer ID Application" identity) and
#   MACOS_CERT_PASSWORD: Developer ID signature, hardened runtime, the entitlements in
#   scripts/entitlements/. Plus APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD (an
#   app-specific password): notarized and stapled.
#   Without them: signed ad hoc (as build.sh already does), not notarized; the release notes
#   say how to open it anyway.
#
# Writes dist/pi-desk-<version>-macos-arm64.zip, its .sha256 and release-notes.md.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

VERSION="" TAG="" UPLOAD=1 BUILD=1 PACKAGE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION=${2:?--version needs a value}; shift 2 ;;
    --tag) TAG=${2:?--tag needs a value}; shift 2 ;;
    --no-upload) UPLOAD=0; shift ;;
    --skip-build) BUILD=0; shift ;;
    --upload-only) BUILD=0; PACKAGE=0; shift ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "release: unknown argument $1" >&2; exit 2 ;;
  esac
done
if [ $PACKAGE = 0 ] && [ $UPLOAD = 0 ]; then
  echo "release: --upload-only and --no-upload leave nothing to do" >&2; exit 2
fi

if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
  echo "release: macOS arm64 only (the browser tab's CEF is wired up for arm64)" >&2; exit 1
fi

# --- version -------------------------------------------------------------------------
if [ -z "$VERSION" ]; then
  if [ -n "$TAG" ]; then VERSION=$TAG
  elif [ -n "${GITHUB_REF_NAME:-}" ] && [ "${GITHUB_REF_TYPE:-}" = tag ]; then VERSION=$GITHUB_REF_NAME
  else VERSION=$(git describe --tags --exact-match --match 'v*' HEAD 2>/dev/null || true)
  fi
fi
VERSION=${VERSION#v}
if ! printf %s "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'; then
  echo "release: no usable version (got '$VERSION'): pass --version X.Y.Z or tag HEAD vX.Y.Z" >&2
  exit 1
fi
[ -n "$TAG" ] || TAG="v$VERSION"
# Info.plist takes up to three integers: 1.2.3-beta.1 ships as 1.2.3 (the zip keeps the full name)
PLIST_VERSION=$(printf %s "$VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')

DIST=dist
NAME="pi-desk-$VERSION-macos-arm64"
NOTES="$DIST/release-notes.md"

TMP=""
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
if [ $BUILD = 1 ]; then
  ./build.sh test
  ./build.sh # release build with CEF; bundle-app.sh lays out and ad-hoc signs build/pi-desk.app
fi
[ -x build/pi-desk.app/Contents/MacOS/pi-desk ] || { echo "release: no build/pi-desk.app (run ./build.sh)" >&2; exit 1; }
[ -d "build/pi-desk.app/Contents/Frameworks/Chromium Embedded Framework.framework" ] ||
  { echo "release: build/pi-desk.app has no CEF framework (a PI_DESK_NO_CEF build?)" >&2; exit 1; }

STAGE="$DIST/stage"
APP="$STAGE/pi-desk.app"
FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
rm -rf "$STAGE" "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256" "$NOTES"
mkdir -p "$STAGE"
ditto build/pi-desk.app "$APP"

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
TMP=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pi-desk-release.XXXXXX")

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
  echo "pi-desk $VERSION for macOS 14 or later on Apple silicon (arm64)."
  echo
  echo "Download \`$NAME.zip\` and check it against \`$NAME.zip.sha256\`:"
  echo
  echo '```sh'
  echo "shasum -a 256 -c $NAME.zip.sha256"
  echo '```'
  echo
  if [ $NOTARIZED = 1 ]; then
    echo "The app is signed with a Developer ID and notarized by Apple."
  else
    echo "**This app is not signed with an Apple Developer ID or notarized** (it is signed ad hoc),"
    echo "so macOS refuses to open it the first time. After unzipping and moving \`pi-desk.app\` to"
    echo "Applications, either right-click it and choose **Open** (macOS 14), or open it once and then"
    echo "click **Open Anyway** in System Settings › Privacy & Security (macOS 15 and later), or clear"
    echo "the quarantine flag:"
    echo
    echo '```sh'
    echo "xattr -dr com.apple.quarantine /Applications/pi-desk.app"
    echo '```'
  fi
  echo
  echo "pi-desk runs your own [pi](https://www.npmjs.com/package/@earendil-works/pi-coding-agent);"
  echo "[pi-kit](https://github.com/McFalljb/pi-kit) is optional. Third-party licences are in"
  echo "\`pi-desk.app/Contents/Resources/licenses/\`."
} > "$NOTES"

echo "release: $DIST/$NAME.zip ($(du -h "$DIST/$NAME.zip" | cut -f1)), signature: $SIGNED, notarized: $NOTARIZED"
cat "$DIST/$NAME.zip.sha256"
cleanup
fi # PACKAGE

# --- draft GitHub Release ------------------------------------------------------------
if [ $UPLOAD = 0 ]; then
  echo "release: --no-upload: stopping before GitHub"
  exit 0
fi
for f in "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256" "$NOTES"; do
  [ -s "$f" ] || { echo "release: $f missing (package first)" >&2; exit 1; }
done
(cd "$DIST" && shasum -a 256 -c "$NAME.zip.sha256") >/dev/null ||
  { echo "release: $DIST/$NAME.zip does not match its .sha256" >&2; exit 1; }
command -v gh >/dev/null || { echo "release: gh (GitHub CLI) is needed to upload" >&2; exit 1; }
REPO_ARG=""
[ -n "${GITHUB_REPOSITORY:-}" ] && REPO_ARG="--repo $GITHUB_REPOSITORY"
PRERELEASE=""
case "$VERSION" in *-*) PRERELEASE="--prerelease" ;; esac
# shellcheck disable=SC2086 # REPO_ARG and PRERELEASE are flags or nothing
if gh release view "$TAG" $REPO_ARG >/dev/null 2>&1; then
  # a re-run: replace the assets, but only on a release nobody has published yet
  IS_DRAFT=$(gh release view "$TAG" $REPO_ARG --json isDraft -q .isDraft)
  if [ "$IS_DRAFT" != true ]; then
    echo "release: $TAG is already published: refusing to replace its assets" >&2
    exit 1
  fi
  gh release upload "$TAG" $REPO_ARG --clobber "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256"
else
  # --generate-notes appends GitHub's notes (changes since the previous release) to ours
  gh release create "$TAG" $REPO_ARG --draft --verify-tag $PRERELEASE --title "pi-desk $VERSION" \
    --notes-file "$NOTES" --generate-notes "$DIST/$NAME.zip" "$DIST/$NAME.zip.sha256"
fi
echo "release: draft release $TAG updated"
