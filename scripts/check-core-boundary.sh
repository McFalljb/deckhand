#!/bin/sh
# The core and the holder link no window code (docs/plans/background-core.md §10.2, "How the
# compiler enforces the boundary"). Odin already refuses a core file that uses a window name (no
# import cycles, `package main` can't be imported); this catches what it can't. Fails if a file
# in src/core/ or src/holder/ (tests too):
#   - imports anything but base:*, core:* (not core:sys/darwin/Foundation, the Obj-C bindings),
#     and the pure packages beside it: ../ghostty, ../holderwire, ../updatesig, ../jsonguard,
#     ../trust, ../corewire (the holder: ../holderwire, ../trust and ../jsonguard only);
#   - has a foreign import other than system: libraries (so no build/dh_*.a, the Obj-C shims);
#   - uses intrinsics.objc_* or an @(objc_*) attribute.
#
#   scripts/check-core-boundary.sh [ROOT]   ROOT: the tree to check (default: this one; the test,
#                                           tests/check-core-boundary-test.sh, passes a copy)
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$ROOT"

check_dir() { # folder, allowed relative imports (space-separated)
  dir=$1 allowed=$2
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.odin; do
    [ -f "$f" ] || continue
    # imports: `import "x"` / `import name "x"`, one per line (odinfmt's form)
    grep -nE '^[[:space:]]*import[[:space:]]' "$f" | while IFS= read -r line; do
      n=${line%%:*}
      path=$(printf '%s\n' "$line" | sed -n 's/.*"\([^"]*\)".*/\1/p')
      case "$path" in
        base:*) ;;
        core:sys/darwin/Foundation*) echo "$f:$n: imports $path (Obj-C bindings)" ;;
        core:*) ;;
        *)
          ok=0
          for a in $allowed; do [ "$path" = "$a" ] && ok=1; done
          [ $ok = 1 ] || echo "$f:$n: imports $path"
          ;;
      esac
    done
    # foreign imports: every quoted library must be system:
    grep -nE '^[[:space:]]*foreign[[:space:]]+import' "$f" | while IFS= read -r line; do
      n=${line%%:*}
      rest=${line#*:}
      # the block form spans lines: take the lines up to the closing brace
      case "$rest" in
        *"{"*) libs=$(sed -n "$n,/}/p" "$f") ;;
        *) libs=$rest ;;
      esac
      printf '%s\n' "$libs" | grep -oE '"[^"]*"' | tr -d '"' | while IFS= read -r lib; do
        case "$lib" in system:*) ;; *) echo "$f:$n: foreign import $lib (not a system: library)" ;; esac
      done
    done
    grep -nE 'intrinsics\.objc_|@\(objc_|@\([^)]*\bobjc_' "$f" | sed "s|^|$f:|;s|\$| (Obj-C)|" || true
  done
}

out=$(
  check_dir src/core "../ghostty ../holderwire ../updatesig ../jsonguard ../trust ../corewire"
  check_dir src/holder "../holderwire ../trust ../jsonguard"
)
if [ -n "$out" ]; then
  printf '%s\n' "$out" | while IFS= read -r l; do echo "check-core-boundary: $l"; done
  echo "check-core-boundary: FAILED: src/core and src/holder must not link window code (docs/plans/background-core.md §10.2)"
  exit 1
fi
n=$(ls src/core/*.odin 2>/dev/null | wc -l | tr -d ' ')
h=$(ls src/holder/*.odin 2>/dev/null | wc -l | tr -d ' ')
echo "check-core-boundary: ok ($n core files, $h holder files)"
