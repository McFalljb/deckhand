#!/bin/sh
# The vendored zstd decoder (vendor/zstd/zstddeclib.c, zstd's single-file decoder: vendor/zstd/VERSION)
# compiled into build/zstd/libzstddec.a, which src/zstd links (the core reads Codex's compressed
# rollouts with it: src/core/codex_disk.odin). Rebuilt only when the source or this script is newer.
# Run by build.sh, tests/unit.py, scripts/pack-linux.sh and CI's linux job before anything that
# links the core; `odin check` does not need it.
#   macOS: clang for MACOSX_DEPLOYMENT_TARGET (build.sh's 14.0 when unset)
#   Linux: cc (CC), position independent
# Usage: scripts/build-zstd.sh   (from anywhere)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SRC=vendor/zstd/zstddeclib.c
OUT=build/zstd/libzstddec.a
if [ -f "$OUT" ] && [ ! "$SRC" -nt "$OUT" ] && [ ! scripts/build-zstd.sh -nt "$OUT" ]; then exit 0; fi
mkdir -p build/zstd
# its own temporary names: two builds at once (unit.py beside build.sh) each rename a whole archive in
TMP_O=build/zstd/.zstddeclib.$$.o TMP_A=build/zstd/.libzstddec.$$.a
trap 'rm -f "$TMP_O" "$TMP_A"' EXIT
case "$(uname -s)" in
  Darwin) clang -c -O2 -w -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-14.0}" "$SRC" -o "$TMP_O" ;;
  *) ${CC:-cc} -c -O2 -w -fPIC "$SRC" -o "$TMP_O" ;;
esac
ar rcs "$TMP_A" "$TMP_O"
mv -f "$TMP_A" "$OUT"
echo "built $OUT"
