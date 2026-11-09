#!/bin/sh
# The core and the holder link no window code (docs/plans/background-core.md §10.2, "How the
# compiler enforces the boundary"). Odin already refuses a core file that uses a window name (no
# import cycles, `package main` can't be imported); this catches what it can't. Fails if a file
# in src/core/ or src/holder/, or in the pure packages they import (src/ghostty, src/jsonguard,
# src/trust, src/corewire, src/updatesig, src/holderwire), tests too:
#   - imports anything but base:*, core:* (not core:sys/darwin/Foundation, the Obj-C bindings),
#     and the pure packages beside it: the core ../ghostty, ../holderwire, ../updatesig,
#     ../jsonguard, ../trust, ../corewire; the holder ../holderwire, ../trust and ../jsonguard;
#     holderwire ../jsonguard; the others none;
#   - has a foreign import other than system: libraries (so no build/dh_*.a, the Obj-C shims;
#     ghostty may link its vendored vendor/libghostty-vt);
#   - names a dh_ symbol in a foreign block (the shims' prefix);
#   - uses intrinsics.objc_* (under any import name) or an objc_* attribute (on one line or
#     across several).
#
# src/coremain (deckhand-core-serve) may import only ../core and ../holder besides base:*/core:*.
#
#   scripts/check-core-boundary.sh [ROOT]   ROOT: the tree to check (default: this one; the test,
#                                           tests/check-core-boundary-test.sh, passes a copy)
set -eu
ROOT=${1:-$(cd "$(dirname "$0")/.." && pwd)}
cd "$ROOT"

check_dir() { # folder, allowed relative imports, allowed non-system foreign imports (globs)
  dir=$1 allowed=$2 foreign=${3:-}
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.odin; do
    [ -f "$f" ] || continue
    # imports: `import "x"` / `import name "x"`, one per line (odinfmt's form)
    grep -nE '^[[:space:]]*import[[:space:]]' "$f" | while IFS= read -r line; do
      n=${line%%:*}
      path=$(printf '%s\n' "$line" | sed -n 's/^[^"]*"\([^"]*\)".*/\1/p')
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
      # the block form: on its one line, or up to the line with the closing brace
      case "$rest" in
        *"{"*"}"*) libs=$rest ;;
        *"{"*) libs=$(sed -n "$n,/}/p" "$f") ;;
        *) libs=$rest ;;
      esac
      printf '%s\n' "$libs" | grep -oE '"[^"]*"' | tr -d '"' | while IFS= read -r lib; do
        ok=0
        case "$lib" in system:*) ok=1 ;; esac
        for a in $foreign; do case "$lib" in $a) ok=1 ;; esac; done
        [ $ok = 1 ] || echo "$f:$n: foreign import $lib (not a system: library)"
      done
    done
    # a dh_ name inside a `foreign lib { ... }` block (a declaration or a link_name)
    awk -v f="$f" '
      !inb && /^[[:space:]]*(@\([^)]*\)[[:space:]]*)*foreign([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)?[[:space:]]*\{/ && !/foreign[[:space:]]+import/ { inb = 1; d = 0 }
      inb {
        line = $0; sub(/\/\/.*/, "", line)
        if (line ~ /(^|[^A-Za-z0-9_])dh_/) print f ":" NR ": " $0 " (a dh_ shim symbol)"
        d += gsub(/\{/, "{", line) - gsub(/\}/, "}", line)
        if (d <= 0) inb = 0
      }' "$f"
    # Obj-C: intrinsics.objc_* by any import name (a call, or a name after a dot), an objc_*
    # attribute on one line or with its fields on lines of their own
    grep -nE 'intrinsics\.objc_|[A-Za-z0-9_]\.objc_[A-Za-z0-9_]|(^|[^A-Za-z0-9_])objc_[a-z_]+\(|@\(objc_|@\([^)]*objc_|^[[:space:]]*objc_[A-Za-z0-9_]*[[:space:]]*=' "$f" | sed "s|^|$f:|;s|\$| (Obj-C)|" || true
  done
}

out=$(
  check_dir src/core "../ghostty ../holderwire ../updatesig ../jsonguard ../trust ../corewire"
  check_dir src/holder "../holderwire ../trust ../jsonguard"
  check_dir src/ghostty "" "../../vendor/libghostty-vt/*"
  check_dir src/jsonguard ""
  check_dir src/trust ""
  check_dir src/corewire ""
  check_dir src/updatesig ""
  check_dir src/holderwire "../jsonguard"
  # deckhand-core-serve's headless main: the core and the holder only (its Obj-C shim is allowed)
  for f in src/coremain/*.odin; do
    [ -f "$f" ] || continue
    grep -nE '^[[:space:]]*import[[:space:]]' "$f" | while IFS= read -r line; do
      path=$(printf '%s\n' "$line" | sed -n 's/^[^"]*"\([^"]*\)".*/\1/p')
      case "$path" in (base:*|core:*|../core|../holder) ;; (*) echo "$f:${line%%:*}: imports $path" ;; esac
    done
  done
)
if [ -n "$out" ]; then
  printf '%s\n' "$out" | while IFS= read -r l; do echo "check-core-boundary: $l"; done
  echo "check-core-boundary: FAILED: src/core and src/holder must not link window code (docs/plans/background-core.md §10.2)"
  exit 1
fi
n=$(ls src/core/*.odin 2>/dev/null | wc -l | tr -d ' ')
h=$(ls src/holder/*.odin 2>/dev/null | wc -l | tr -d ' ')
echo "check-core-boundary: ok ($n core files, $h holder files)"
