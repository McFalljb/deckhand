#!/bin/sh
# Screenshots of the UI font (build/shots/font/TAG-*.png): the looks scene's fake
# store and pi (tests/scripts/looks.sh) with script font.txt.
# Usage: tests/scripts/font.sh TAG
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TAG=${1:-now}
mkdir -p "$ROOT/build"
sed "s/\$FONT_TAG/$TAG/g" "$ROOT/tests/scripts/font.txt" > "$ROOT/build/font-$TAG.txt"
exec "$ROOT/tests/scripts/looks.sh" "$ROOT/build/font-$TAG.txt"
