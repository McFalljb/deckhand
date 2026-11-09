#!/bin/sh
# scripts/check-core-boundary.sh catches each forbidden thing (docs/plans/background-core.md
# §10.2): in a temporary tree with a clean core and holder it passes, and each planted import,
# foreign import or Obj-C use makes it fail. A few seconds; run by ./build.sh test.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/boundary.XXXXXX")
trap 'rm -rf "$T"' EXIT
CHECK="$ROOT/scripts/check-core-boundary.sh"

mkdir -p "$T/src/core" "$T/src/holder"
cat > "$T/src/core/clean.odin" <<'ODIN'
package core

import "base:runtime"
import "core:fmt"
import "core:sys/posix"
import gh "../ghostty"
import jg "../jsonguard"
import "../holderwire"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}
foreign import multi {"system:System", "system:c"}
// the one-line block form, then a string and a brace further down (read no further than the line)
foreign import libc2 {"system:c", "system:util"}
hello :: proc() { fmt.println("hello") }
ODIN
cat > "$T/src/holder/clean.odin" <<'ODIN'
package main

import "core:fmt"
import "../holderwire"
import "../trust"
ODIN
# the pure packages beside the core: their own imports are checked too (holderwire may use
# jsonguard, ghostty its vendored library)
mkdir -p "$T/src/ghostty" "$T/src/jsonguard" "$T/src/trust" "$T/src/corewire" "$T/src/updatesig" "$T/src/holderwire"
cat > "$T/src/ghostty/clean.odin" <<'ODIN'
package ghostty

import "core:c"

when ODIN_ARCH == .arm64 {
	foreign import lib "../../vendor/libghostty-vt/aarch64-macos/lib/libghostty-vt.a"
}
ODIN
for p in jsonguard trust corewire updatesig; do
  printf 'package %s\n\nimport "core:fmt"\nforeign import libc "system:System"\n' $p > "$T/src/$p/clean.odin"
done
printf 'package holderwire\n\nimport "core:fmt"\nimport jg "../jsonguard"\n' > "$T/src/holderwire/clean.odin"
"$CHECK" "$T" >/dev/null || { echo "check-core-boundary-test: a clean tree failed"; "$CHECK" "$T"; exit 1; }

fails=0 planted=0
plant() { # folder, what, line
  planted=$((planted + 1))
  cp "$T/src/$1/clean.odin" "$T/src/$1/clean.odin.bak"
  printf '%s\n' "$3" >> "$T/src/$1/clean.odin"
  if "$CHECK" "$T" >/dev/null 2>&1; then
    echo "check-core-boundary-test: FAILED: $2 in src/$1 passed"
    fails=$((fails + 1))
  fi
  mv "$T/src/$1/clean.odin.bak" "$T/src/$1/clean.odin"
}
plant core "sokol" 'import sapp "../../vendor/sokol-odin/sokol/app"'
plant core "Clay" 'import clay "../../build/clay-odin"'
plant core "the window package" 'import "../"'
plant core "Foundation" 'import NS "core:sys/darwin/Foundation"'
plant core "a vendor: package" 'import stbi "vendor:stb/image"'
plant core "a shim" 'foreign import dhframes "../../build/dh_frames.a"'
plant core "a shim in a block" 'foreign import pdx {
	"system:Metal.framework",
	"../../build/dh_cef.a",
}'
plant core "intrinsics.objc_*" 'x :: proc() { _ = intrinsics.objc_find_class("NSApp") }'
plant core "an @(objc_*) attribute" '@(objc_type = NSThing, objc_name = "foo")'
plant holder "ghostty" 'import gh "../ghostty"'
plant core "a window import with a quoted core: path after it" 'import sapp "../../vendor/sokol-odin/sokol/app" // not "core:fmt"'
plant core "intrinsics.objc_* under an alias" 'import intr "base:intrinsics"
x :: proc() { _ = intr.objc_find_class("NSApp") }'
plant core "an @(objc_*) attribute across lines" '@(
	objc_type = NSThing,
)
Thing :: struct {}'
plant core "a dh_ shim symbol in a foreign block" 'foreign libc {
	dh_cef_init :: proc() ---
}'
plant core "a dh_ shim link_name" 'foreign libc {
	@(link_name = "dh_frames_begin")
	frames_begin :: proc() ---
}'
for p in ghostty jsonguard trust corewire updatesig holderwire; do
  plant $p "Foundation" 'import NS "core:sys/darwin/Foundation"'
  plant $p "sokol" 'import sapp "../../vendor/sokol-odin/sokol/app"'
  plant $p "a shim" 'foreign import dhframes "../../build/dh_frames.a"'
  plant $p "intrinsics.objc_*" 'x :: proc() { _ = intrinsics.objc_find_class("NSApp") }'
done
plant ghostty "another vendored library" 'foreign import cef "../../vendor/cef/libcef.a"'
plant jsonguard "holderwire" 'import "../holderwire"'
plant holder "sokol" 'import sapp "../../vendor/sokol-odin/sokol/app"'
if [ $fails != 0 ]; then exit 1; fi
echo "check-core-boundary-test: ok ($planted planted imports refused)"
