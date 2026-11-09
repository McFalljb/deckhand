#!/bin/sh
# Install Deckhand (macOS, Apple silicon) from its GitHub Releases:
#
#   curl -fsSL https://raw.githubusercontent.com/McFalljb/deckhand/main/scripts/install.sh | sh
#
# Options (after `sh -s --` when piped):
#   --version X.Y.Z   that release instead of the latest (or DECKHAND_VERSION=X.Y.Z)
#   --dir PATH        install into PATH instead of /Applications (~/Applications when
#                     /Applications is not writable; an existing ~/Applications copy is updated there)
#
# What it does: downloads deckhand-<version>-macos-arm64.zip and its .sha256 over HTTPS, checks
# the SHA-256, unpacks Deckhand.app next to where it goes, swaps it in for any old copy, clears
# the quarantine flag and checks the app's code signature (codesign --verify --deep --strict).
# It never uses sudo and never stops a running Deckhand.
#
# The release's updater signature (.sig, Ed25519 over a manifest: src/updatesig) is NOT checked
# here: a stock Mac has no Ed25519 tool (its openssl is LibreSSL 3.3, without Ed25519), and this
# script adds no dependencies. It relies on HTTPS to GitHub plus the SHA-256 and codesign. The
# in-app updater does check the .sig.
set -eu

REPO=McFalljb/deckhand
UA="deckhand-install-script"   # generic on purpose: nothing about the user
VERSION=${DECKHAND_VERSION:-}
DIR=""

die() { echo "deckhand install: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) [ $# -ge 2 ] || die "--version needs a value (X.Y.Z)"; VERSION=$2; shift 2 ;;
    --dir) [ $# -ge 2 ] || die "--dir needs a path"; DIR=$2; shift 2 ;;
    *) die "unknown option: $1 (options: --version X.Y.Z, --dir PATH)" ;;
  esac
done
VERSION=${VERSION#v}
if [ -n "$VERSION" ]; then
  echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "not a version: $VERSION (expected X.Y.Z)"
fi

# --- this Mac --------------------------------------------------------------------------------
[ "$(uname -s)" = Darwin ] || die "Deckhand runs on macOS only."
# hw.optional.arm64: also true in a shell running under Rosetta, where uname -m says x86_64
[ "$(uname -m)" = arm64 ] || [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] ||
  die "Deckhand needs a Mac with Apple silicon (arm64); Intel Macs are not supported."

# --- a running Deckhand is never stopped -----------------------------------------------------
if pgrep -x Deckhand >/dev/null 2>&1 || pgrep -f 'MacOS/deckhand-core-serve' >/dev/null 2>&1; then
  cat >&2 <<'EOF'
deckhand install: Deckhand is running, so nothing was changed.
  To update it and keep your sessions running, use the in-app updater
  (Deckhand > Check for Updates...): this script cannot carry sessions across.
  Or quit with Deckhand > Quit Deckhand and Stop All Sessions..., then run this again.
EOF
  exit 1
fi

# --- where it goes ---------------------------------------------------------------------------
if [ -z "$DIR" ]; then
  if [ ! -e /Applications/Deckhand.app ] && [ -e "$HOME/Applications/Deckhand.app" ]; then
    DIR=$HOME/Applications
  elif [ -w /Applications ]; then
    DIR=/Applications
  else
    DIR=$HOME/Applications
  fi
fi
mkdir -p "$DIR" || die "cannot create $DIR"
[ -w "$DIR" ] || die "$DIR is not writable (try --dir \"\$HOME/Applications\")"
DIR=$(cd "$DIR" && pwd)
APP=$DIR/Deckhand.app

# --- which release ---------------------------------------------------------------------------
if [ -z "$VERSION" ]; then
  VERSION=$(curl -fsSL -A "$UA" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/$REPO/releases/latest" |
    grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"v\{0,1\}\([^"]*\)"$/\1/') || VERSION=""
  echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
    die "could not find the latest release on GitHub (offline, or its API's hourly limit: try --version X.Y.Z)"
fi
NAME=deckhand-$VERSION-macos-arm64.zip
URL=https://github.com/$REPO/releases/download/v$VERSION

# --- download and check ----------------------------------------------------------------------
TMP=$(mktemp -d "${TMPDIR:-/tmp}/deckhand-install.XXXXXX")
STAGE=""
cleanup() { rm -rf "$TMP"; [ -z "$STAGE" ] || rm -rf "$STAGE"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

echo "Downloading Deckhand $VERSION..."
curl -fSL --progress-bar -A "$UA" -o "$TMP/$NAME" "$URL/$NAME" || die "download failed: $URL/$NAME"
curl -fsSL -A "$UA" -o "$TMP/$NAME.sha256" "$URL/$NAME.sha256" || die "download failed: $URL/$NAME.sha256"
(cd "$TMP" && shasum -a 256 -c "$NAME.sha256" >/dev/null 2>&1) ||
  die "the download does not match its SHA-256 ($NAME.sha256): not installed"
echo "SHA-256 ok."

# --- unpack next to the destination, then swap ----------------------------------------------
# Unpacked in a folder inside $DIR, so the moves below are renames on one disk.
STAGE=$(mktemp -d "$DIR/.deckhand-install.XXXXXX")
ditto -x -k "$TMP/$NAME" "$STAGE" || die "could not unpack $NAME"
[ "$(ls -A "$STAGE")" = Deckhand.app ] || die "$NAME does not hold exactly Deckhand.app: not installed"
NEW=$STAGE/Deckhand.app
# no quarantine flag comes with curl, but clear it in case something set one
xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true
codesign --verify --deep --strict "$NEW" 2>"$TMP/codesign.log" ||
  die "the app's code signature does not verify: not installed ($(tr '\n' ' ' < "$TMP/codesign.log"))"
GOT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW/Contents/Info.plist" 2>/dev/null || true)
[ "$GOT" = "$VERSION" ] || die "the app in $NAME says version '$GOT', not $VERSION: not installed"

OLD=""
if [ -e "$APP" ]; then
  OLD=$DIR/.Deckhand.app.old.$$   # outside $STAGE: never deleted unless the new one is in place
  mv "$APP" "$OLD" || die "could not move the old $APP aside"
fi
if ! mv "$NEW" "$APP"; then
  [ -z "$OLD" ] || mv "$OLD" "$APP" || die "could not move the new Deckhand.app in; the old one is at $OLD"
  die "could not move the new Deckhand.app into $DIR"
fi
if [ -n "$OLD" ]; then
  rm -rf "$OLD" || echo "deckhand install: could not delete the old copy at $OLD; delete it by hand" >&2
fi

echo "Installed Deckhand $VERSION in $APP (signature verified)."

# --- after -----------------------------------------------------------------------------------
for p in /Applications/pi-desk.app "$HOME/Applications/pi-desk.app"; do
  if [ -e "$p" ]; then
    echo "Note: $p is still there. Deckhand used to be called pi-desk: quit pi-desk and delete it"
    echo "      (the two can't run at the same time). Your projects, sessions and settings carry over."
  fi
done
echo
echo "Open it with:  open -a \"$APP\""
if [ "$DIR" = /Applications ] || [ "$DIR" = "$HOME/Applications" ]; then
  echo "          or:  open -a Deckhand"
fi
echo "Installed this way it has no quarantine flag, so macOS opens it without a Gatekeeper prompt."
echo "Later updates come through the app (Deckhand > Check for Updates...)."
