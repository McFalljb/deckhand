#!/bin/sh
# The Linux core's release tarball (docs/DEVELOPING.md "Releases"; docs/plans/background-core.md
# §10.4 M6-L4), built by .github/workflows/release-linux.yml on ubuntu-latest:
#   deckhand-core-X.Y.Z-linux-x86_64.tar.gz, one folder deckhand-core-X.Y.Z-linux-x86_64/ holding
#     deckhand-core-serve   the core (-define:DECKHAND_TEST_HOOKS=false, DECKHAND_VERSION=X.Y.Z)
#     deckhand-core         the session holder (its test hooks are off unless asked for)
#     deckhand              the CLI (tools/deckhand-cli)
#     pi/  claude-code/     the integrations (pi/ is build.sh's build_pi set)
#     LICENSE  THIRD_PARTY_NOTICES.md
# Regular files and folders only (no links), owner 0:0, modes 0755/0644, sorted, every mtime the
# commit's, gzip without a name or time. It checks the binaries for test hooks
# (scripts/check-release-build.sh) and prints "tarball-sha256 HEX NAME", the line
# scripts/release-linux.sh checks the downloaded artifact against. No key, no secret.
# Usage: scripts/pack-linux.sh X.Y.Z OUT_DIR   (on Linux x86_64, from a clean checkout)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
[ $# = 2 ] || { echo "usage: scripts/pack-linux.sh X.Y.Z OUT_DIR" >&2; exit 2; }
VERSION=$1 OUT=$2
printf %s "$VERSION" | grep -Eq '^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$' ||
  { echo "pack-linux: the version must be X.Y.Z (got '$VERSION')" >&2; exit 2; }
[ "$(uname -s)-$(uname -m)" = Linux-x86_64 ] || { echo "pack-linux: Linux x86_64 only" >&2; exit 1; }
# the name, from the source the signer and M6-E's verifier read (src/updatesig/updatesig.odin)
PREFIX=$(sed -n 's/^LINUX_TAR_PREFIX :: "\(.*\)"$/\1/p' src/updatesig/updatesig.odin)
SUFFIX=$(sed -n 's/^LINUX_TAR_SUFFIX :: "\(.*\)"$/\1/p' src/updatesig/updatesig.odin)
case "$PREFIX$SUFFIX" in *-linux-x86_64.tar.gz) ;; *) echo "pack-linux: no LINUX_TAR_PREFIX/SUFFIX in src/updatesig/updatesig.odin" >&2; exit 1 ;; esac
NAME=$PREFIX$VERSION$SUFFIX
TOP=${NAME%.tar.gz}

B=$(mktemp -d "${TMPDIR:-/tmp}/deckhand-pack.XXXXXX")
trap 'rm -rf "$B"' EXIT
trap 'rm -rf "$B"; exit 130' INT TERM
S=$B/$TOP
mkdir -p "$S" "$OUT"
odin build src/coremain -out:"$S/deckhand-core-serve" -o:speed -define:DECKHAND_TEST_HOOKS=false -define:DECKHAND_VERSION="$VERSION"
odin build src/holder -out:"$S/deckhand-core" -o:speed
odin build tools/deckhand-cli -out:"$S/deckhand" -o:speed
# what pi loads (build.sh's build_pi: its tests stay behind), and the Claude Code plugin
mkdir "$S/pi"
cp -R integrations/pi/extensions integrations/pi/lib integrations/pi/skills "$S/pi/"
cp integrations/pi/extensions.json integrations/pi/package.json integrations/pi/README.md "$S/pi/"
cp -R integrations/claude-code "$S/claude-code"
cp LICENSE THIRD_PARTY_NOTICES.md "$S/"

scripts/check-release-build.sh "$S/deckhand-core-serve" "$S/deckhand-core" "$S/deckhand"
# the version is baked in (core_version, the install's key and the hello)
GOT=$("$S/deckhand-core-serve" check | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')
[ "$GOT" = "$VERSION" ] || { echo "pack-linux: deckhand-core-serve check says version '$GOT', not $VERSION" >&2; exit 1; }
# regular files and folders only: no link may point out of the tree
ODD=$(find "$S" ! -type f ! -type d)
[ -z "$ODD" ] || { echo "pack-linux: not a file or folder: $ODD" >&2; exit 1; }

EPOCH=$(git log -1 --format=%ct HEAD)
rm -f "$OUT/$NAME"
tar --create --format=gnu --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$EPOCH" \
  --mode='u=rwX,go=rX' -C "$B" -- "$TOP" | gzip -9 -n > "$OUT/$NAME"
tar -tvzf "$OUT/$NAME"
SUM=$(sha256sum "$OUT/$NAME" | cut -d' ' -f1)
echo "tarball-sha256 $SUM $NAME"
