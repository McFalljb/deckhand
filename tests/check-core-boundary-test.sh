#!/bin/sh
# scripts/check-core-boundary.sh catches each forbidden thing (docs/plans/background-core.md
# §10.2): in a temporary tree with a clean core and holder it passes, and each planted import,
# foreign import or Obj-C use makes it fail. Under a second; run by ./build.sh test.
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
ODIN
cat > "$T/src/holder/clean.odin" <<'ODIN'
package main

import "core:fmt"
import "../holderwire"
import "../trust"
ODIN
"$CHECK" "$T" >/dev/null || { echo "check-core-boundary-test: a clean tree failed"; "$CHECK" "$T"; exit 1; }

fails=0
plant() { # folder, what, line
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
plant holder "sokol" 'import sapp "../../vendor/sokol-odin/sokol/app"'
if [ $fails != 0 ]; then exit 1; fi
echo "check-core-boundary-test: ok (11 planted imports refused)"
