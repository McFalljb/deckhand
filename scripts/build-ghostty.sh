#!/bin/sh
# Build libghostty-vt static libraries for all targets from the pinned
# Ghostty source (vendor/ghostty) with the project-local Zig (toolchain/).
# Output: vendor/libghostty-vt/<target>/lib/<static lib>, shared include/, VERSION.
# Usage: scripts/build-ghostty.sh [target ...]   (default: all targets)
#
# Each archive is repacked after the Zig build:
#  - debug info stripped (~12-22 MB -> ~3 MB per target);
#  - member names reduced to basenames (Zig records absolute cache paths);
#  - compiler_rt symbols made weak: Zig bundles compiler_rt into static libs and
#    its builtins (__udivti3, ...) clash with the Odin runtime's copies. Weak
#    keeps the ones only compiler_rt has (e.g. __extenddftf2).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ZIG="$ROOT/toolchain/zig-aarch64-macos-0.17.0/zig"
SRC="$ROOT/vendor/ghostty"
OUT="$ROOT/vendor/libghostty-vt"
TARGETS=${*:-"aarch64-macos x86_64-macos x86_64-linux-gnu aarch64-linux-gnu x86_64-windows-gnu"}

[ -x "$ZIG" ] || { echo "missing $ZIG (see README: toolchain)"; exit 1; }
# LLVM binutils (llvm-objcopy/llvm-ar handle Mach-O, ELF and COFF alike).
LLVM_BIN=${LLVM_BIN:-$(dirname "$(readlink -f "$(command -v clang)")")}
OBJCOPY="$LLVM_BIN/objcopy"; [ -x "$LLVM_BIN/llvm-objcopy" ] && OBJCOPY="$LLVM_BIN/llvm-objcopy"
LLVM_AR="$LLVM_BIN/ar";      [ -x "$LLVM_BIN/llvm-ar" ] && LLVM_AR="$LLVM_BIN/llvm-ar"
"$OBJCOPY" --version 2>/dev/null | grep -q llvm-objcopy || { echo "need llvm-objcopy in LLVM_BIN"; exit 1; }
"$LLVM_AR" --version 2>/dev/null | grep -q LLVM || { echo "need llvm-ar in LLVM_BIN"; exit 1; }

mkdir -p "$OUT"
rm -rf "$OUT/include"; cp -R "$SRC/include" "$OUT/include"
{
  echo "ghostty_tag=$(git -C "$SRC" describe --tags --exact-match 2>/dev/null || echo none)"
  echo "ghostty_commit=$(git -C "$SRC" rev-parse HEAD)"
  echo "zig_version=$("$ZIG" version)"
  echo "optimize=ReleaseFast debug_info=stripped compiler_rt=weak (COFF: unchanged)"
} > "$OUT/VERSION"

repack() { # $1 = archive, $2 = llvm-ar format
  tmp=$(mktemp -d)
  for m in $("$LLVM_AR" t "$1"); do "$LLVM_AR" p "$1" "$m" > "$tmp/$(basename "$m")" || return 1; done
  for o in "$tmp"/*; do
    case "$(basename "$o")" in
      # llvm-objcopy can't --weaken COFF; Windows linking is untested so far.
      compiler_rt.o) "$OBJCOPY" --strip-debug --weaken "$o" ;;
      *)             "$OBJCOPY" --strip-debug "$o" ;;
    esac || return 1
  done
  rm -f "$1"
  (cd "$tmp" && "$LLVM_AR" rcs --format="$2" "$1" $(ls)) || return 1
  rm -rf "$tmp"
}

status=0
for t in $TARGETS; do
  echo "== $t"
  rm -rf "$OUT/$t"
  case "$t" in *macos*) fmt=darwin ;; *windows*) fmt=coff ;; *) fmt=gnu ;; esac
  if (cd "$SRC" && "$ZIG" build -Demit-lib-vt -Dtarget="$t" -Doptimize=ReleaseFast -Demit-xcframework=false \
        --prefix "$OUT/$t" >"$OUT/$t.log" 2>&1); then
    # keep only the static library (headers are shared in include/)
    find "$OUT/$t" ! -type d ! -name 'libghostty-vt.a' ! -name 'ghostty-vt-static.lib' -delete
    find "$OUT/$t" -type d -empty -delete
    lib=$(find "$OUT/$t" -type f)
    if repack "$lib" "$fmt"; then
      echo "ok: $(ls -l "$lib" | awk '{print $5}') bytes $lib"
      rm -f "$OUT/$t.log"
    else
      echo "FAILED repack: $lib"; status=1
    fi
  else
    echo "FAILED: see $OUT/$t.log"; tail -5 "$OUT/$t.log"; status=1
  fi
done
exit $status
